import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Accelerate
import Synchronization

/// Per-application audio capture built on CoreAudio process taps.
///
/// One tap per application, each surfaced through its own private
/// aggregate device, each driving an IOProc that meters the signal and
/// writes it into that application's ring buffer for the mixer to render.
///
/// The tap is created with `CATapMutedWhenTapped`, which is the whole
/// reason this design works: while MixPill is tapping an app, macOS mutes
/// that app's own path to the speakers. MixPill re-plays the processed
/// copy, and the user hears it exactly once. That is the problem the
/// project previously planned to solve by shipping a DriverKit null sink
/// and making it the system default output — a system extension, an
/// Apple-approved entitlement and an approval prompt, replaced by one
/// property on a public API.
///
/// Taps are also far less failure-prone than the SCStream-per-app design
/// they replace: nothing to restart under backoff, no starvation
/// heartbeat, no permission that can be revoked mid-session. A tap either
/// exists or it does not, and the HAL tells us when the world changes.
final class ProcessTapCapture: @unchecked Sendable {
    /// What the core currently manages to capture, and what it does not.
    ///
    /// This replaces a single `Bool`. With one flag, five successful taps
    /// followed by one failure raised a banner, and the *next* successful
    /// tap cleared it again — leaving an application permanently outside
    /// the mix with nothing on screen to say so.
    struct CaptureState: Sendable, Equatable {
        var captured: Set<String> = []
        /// bundle id → OSStatus of the most recent failure.
        var failures: [String: OSStatus] = [:]
        /// Display names for the failures, in the order they were seen.
        var failureNames: [String] = []
    }

    /// One captured application.
    private final class Tap {
        let bundleID: String
        var tapID: AudioObjectID = kAudioObjectUnknown
        var aggregateID: AudioObjectID = kAudioObjectUnknown
        var ioProcID: AudioDeviceIOProcID?
        var format: AudioStreamBasicDescription?
        /// Deinterleave scratch, allocated once at tap start and owned for
        /// the tap's lifetime — the IOProc must never allocate.
        var scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>
        var scratchChannels: Int
        var scratchFrames: Int
        /// How many channels the tap delivers, and which two of them carry
        /// this app's stereo output.
        var sourceChannelCount = 2
        var sourceLeft = 0
        var sourceRight = 1
        /// Gain that undoes the stereo mixdown's averaging. 1.0 when the
        /// tap is already the device's native width.
        var mixdownCompensation: Float = 1
        /// Host time of the previous IOProc call, and how many arrived
        /// later than the clock allows. CoreAudio's overload notification
        /// only fires when *it* notices; measuring the interval catches
        /// every late block, including the ones it stays quiet about.
        var lastCallbackHostTime: UInt64 = 0
        let lateCallbacks = Atomic<Int>(0)
        var expectedInterval: UInt64 = 0

        /// Latest metering, published lock-free.
        ///
        /// These used to go into a dictionary behind an `UnfairLock` that
        /// the drain also took — while allocating, thirty times a second.
        /// That put the capture IO thread behind a lock held by a
        /// non-real-time thread doing memory work, which is how a callback
        /// misses its deadline and a click reaches the speakers.
        /// `Float.bitPattern` in an atomic needs neither.
        let rmsBits = Atomic<UInt32>(0)
        let peakBits = Atomic<UInt32>(0)

        /// Logged once, the first time real signal arrives. Answers the
        /// single most common support question — "is MixPill even hearing
        /// this app?" — without any ongoing log noise.
        var hasLoggedFirstAudio = false

        init(bundleID: String, channels: Int, frames: Int) {
            self.bundleID = bundleID
            self.scratchChannels = channels
            self.scratchFrames = frames
            scratch = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: channels)
            for channel in 0..<channels {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                buffer.initialize(repeating: 0, count: frames)
                scratch[channel] = buffer
            }
        }

        deinit {
            for channel in 0..<scratchChannels {
                scratch[channel]?.deallocate()
            }
            scratch.deallocate()
        }
    }

    /// Deinterleave scratch depth. Aggregate IOProc blocks are far smaller
    /// than this; the headroom means an unusually large block is still
    /// handled rather than dropped.
    private static let scratchFrames = 8192

    /// Capture-side I/O block, in frames.
    ///
    /// Larger than playback's on purpose. Latency here is absorbed by the
    /// ring, while the deadline pressure that produces
    /// `skipping cycle due to overload` scales with how often the cycle
    /// runs. Measured over four minutes with three apps tapped on a
    /// 64-channel interface: 256 frames gave 13 dropouts, 1024 gave none.
    ///
    /// Ultra-Low Latency trades that headroom back for responsiveness, for
    /// people monitoring live audio who would rather hear the occasional
    /// glitch than the delay.
    private static let standardCaptureFrames: UInt32 = 1024
    private static let lowLatencyCaptureFrames: UInt32 = 256

    /// Ceiling on the stereo-mixdown gain correction.
    ///
    /// The correction is `deviceChannels / 2`, which is exactly right when
    /// the mixdown averages across the device's width. If that assumption
    /// is ever wrong the error is not subtle — it is a 30 dB step — so the
    /// factor is capped at the widest interface the reasoning was verified
    /// against, and anything beyond it is logged rather than applied.
    private static let maximumMixdownCompensation: Float = 32

    private let lowLatency = Atomic<Bool>(false)

    /// Mirrors the user's Ultra-Low Latency preference. Existing taps are
    /// rebuilt by the caller.
    func setLowLatencyEnabled(_ enabled: Bool) {
        lowLatency.store(enabled, ordering: .relaxed)
    }

    private var captureBufferFrames: UInt32 {
        lowLatency.load(ordering: .relaxed) ? Self.lowLatencyCaptureFrames : Self.standardCaptureFrames
    }

    private let lock = UnfairLock()
    private var taps: [String: Tap] = [:]

    /// Serializes every change to the tap table.
    ///
    /// Creating and destroying taps used to happen on whichever queue
    /// happened to call in — the discovery queue via `onProcessesChanged`,
    /// the service queue via `applyConfiguration` / `applyChannel` /
    /// `setLowLatencyEnabled`, and the resilience queue via `restartAll` —
    /// with nothing serializing them. `sync` reads the live set under the
    /// lock and then starts taps outside it, so two overlapping calls could
    /// each decide the same application needed a tap. The second
    /// `taps[bundleID] = tap` then dropped the first from the table without
    /// ever stopping it: its IOProc kept running, its aggregate device kept
    /// existing, and — because a tap mutes what it captures — the app stayed
    /// muted for good once MixPill let go of the copy it still knew about.
    ///
    /// Everything that mutates the table now hops onto this one serial
    /// queue, which also makes `excluded`, the failure table and the
    /// published capture state queue-confined rather than racy.
    private let lifecycleQueue = DispatchQueue(label: "com.mixpill.core.taps", qos: .userInitiated)

    private let mixer: LowLatencyMixerEngine
    private let registry: DeviceRegistry
    /// Overload notifications must not be delivered on an audio thread.
    private let overloadQueue = DispatchQueue(label: "com.mixpill.core.overload", qos: .utility)

    /// Listener blocks keyed by the object they were installed on, so they
    /// can be taken off again. `AudioObjectRemovePropertyListenerBlock`
    /// matches on the block itself, so the reference has to be kept.
    private var overloadListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]

    /// Raised whenever the set of captured or failing applications changes.
    /// The UI shows the failures verbatim rather than inventing an
    /// explanation, and greys out the strips it cannot actually control.
    var onCaptureStateChanged: ((CaptureState) -> Void)?
    /// Supplies the current discovery snapshot so a failed tap can be
    /// retried without waiting for the process list to change.
    var currentProcessesProvider: () -> [AudioProcessRegistry.AudioProcess] = { [] }

    private var captureState = CaptureState()
    private var lastPublishedState: CaptureState?
    private var displayNames: [String: String] = [:]
    private var retryScheduled = false
    private var retryRound = 0

    init(mixer: LowLatencyMixerEngine, registry: DeviceRegistry) {
        self.mixer = mixer
        self.registry = registry
    }

    /// The applications the engine is actually capturing right now. Read
    /// from the service queue when building the app list.
    var capturedBundleIDs: Set<String> {
        lock.withLock { Set(taps.keys) }
    }

    // MARK: - Sync against discovery

    /// Applications to leave completely alone — see `setExcluded`.
    private var excluded: Set<String> = []
    /// Applications the interface has described at all. Until an app is in
    /// here, `DAWDetection` decides for it.
    private var configuredBundleIDs: Set<String> = []

    /// Applications that must not be tapped at all.
    ///
    /// This is what DAW Direct now means. Bypassing the DSP was never
    /// enough: a tapped app is *muted at source* and replayed from the
    /// stereo pair MixPill captured, which for a DAW means its monitoring
    /// latency grows by the capture block, any hiccup here becomes a
    /// dropout there, and any output beyond the captured pair is silenced
    /// outright. A digital audio workstation on a 32-channel interface
    /// wants none of that. Leaving it untapped gives it its own output
    /// path back, exactly as if MixPill were not running.
    ///
    /// The set is the single authority. `DAWDetection` only decides the
    /// *default* value the interface sends for a newly seen app, so the
    /// user can put anything into DAW Direct — and take a DAW back out of
    /// it — instead of the engine second-guessing them.
    /// - Parameters:
    ///   - bundleIDs: applications the interface has put on DAW Direct.
    ///   - configured: every application the interface has described at all.
    ///     A recognised DAW that is *not* in this set has not been
    ///     configured yet, and stays untapped until it is — waiting for the
    ///     first channel snapshot would otherwise mean tapping a DAW for the
    ///     first second of its life, which is exactly when somebody is
    ///     likely to be recording.
    func setExcluded(_ bundleIDs: Set<String>, configured: Set<String>) {
        lifecycleQueue.async { self.performSetExcluded(bundleIDs, configured: configured) }
    }

    /// Aligns live taps with the set of applications we want captured.
    func sync(with processes: [AudioProcessRegistry.AudioProcess]) {
        let queuedAt = Date()
        lifecycleQueue.async {
            let waited = Date().timeIntervalSince(queuedAt)
            if waited > 0.5 {
                MixPillCoreLog.log("ProcessTapCapture: tap work waited \(String(format: "%.2f", waited)) s for the lifecycle queue")
            }
            self.performSync(with: processes)
        }
    }

    func stopAll() {
        lifecycleQueue.async { self.performStopAll() }
    }

    /// After a device or clock change, tear every tap down and rebuild it
    /// against the new world.
    func restartAll(with processes: [AudioProcessRegistry.AudioProcess]) {
        lifecycleQueue.async {
            self.performStopAll()
            self.performSync(with: processes)
        }
    }

    var activeTapCount: Int {
        lock.withLock { taps.count }
    }

    /// Total late capture blocks across every tap.
    var lateCallbackCount: Int {
        lock.withLock { taps.values.reduce(0) { $0 + $1.lateCallbacks.load(ordering: .relaxed) } }
    }

    // MARK: - Lifecycle work (lifecycleQueue only)

    private func performSetExcluded(_ bundleIDs: Set<String>, configured: Set<String>) {
        let added = bundleIDs.subtracting(excluded)
        excluded = bundleIDs
        configuredBundleIDs.formUnion(configured)
        let live = lock.withLock { Set(taps.keys) }
        for bundleID in added where live.contains(bundleID) {
            performStop(bundleID: bundleID)
        }
        // An app taken out of DAW Direct should not have to wait for the
        // next discovery event to be picked up.
        performSync(with: currentProcessesProvider())
    }

    /// Whether this application should be captured right now.
    private func shouldCapture(_ bundleID: String) -> Bool {
        if excluded.contains(bundleID) { return false }
        // Unconfigured DAWs stay untapped. `DAWDetection` only supplies the
        // *default*, so once the interface has described the channel its
        // answer wins — which is what makes the DAW Direct switch on the row
        // able to turn off as well as on.
        if DAWDetection.isDAW(bundleID: bundleID) && !configuredBundleIDs.contains(bundleID) {
            return false
        }
        return true
    }

    private func performSync(with processes: [AudioProcessRegistry.AudioProcess]) {
        for process in processes {
            displayNames[process.bundleID] = process.name
        }

        let wanted = processes.filter { shouldCapture($0.bundleID) }
        let desired = Dictionary(wanted.map { ($0.bundleID, $0) }, uniquingKeysWith: { first, _ in first })
        let active = lock.withLock { Set(taps.keys) }

        for bundleID in active.subtracting(desired.keys) {
            performStop(bundleID: bundleID)
        }

        // Drop failures for apps that are gone or now excluded.
        for bundleID in captureState.failures.keys where desired[bundleID] == nil {
            captureState.failures.removeValue(forKey: bundleID)
        }

        for (bundleID, process) in desired where !active.contains(bundleID) {
            performStart(process: process)
        }

        publishCaptureState()
        scheduleRetryIfNeeded()
    }

    private func performStopAll() {
        let bundleIDs = lock.withLock { Array(taps.keys) }
        for bundleID in bundleIDs {
            performStop(bundleID: bundleID)
        }
        publishCaptureState()
    }

    /// Republishes the capture picture when it actually moved.
    private func publishCaptureState() {
        captureState.captured = lock.withLock { Set(taps.keys) }
        captureState.failureNames = captureState.failures.keys
            .map { displayNames[$0] ?? $0 }
            .sorted()

        guard captureState != lastPublishedState else { return }
        lastPublishedState = captureState
        onCaptureStateChanged?(captureState)
    }

    /// A tap that failed once usually succeeds later — the HAL is briefly
    /// busy after a device change, or the app was mid-launch. Retrying with
    /// a backoff costs nothing (tap creation is stateless) and is the
    /// difference between "that app is permanently outside the mixer" and
    /// "it joined a few seconds late".
    private func scheduleRetryIfNeeded() {
        guard !captureState.failures.isEmpty else {
            retryRound = 0
            return
        }
        guard !retryScheduled else { return }
        retryScheduled = true

        let delay = min(30.0, pow(2.0, Double(retryRound)))
        retryRound += 1
        lifecycleQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.performSync(with: self.currentProcessesProvider())
        }
    }

    // MARK: - Tap lifecycle

    private func performStart(process: AudioProcessRegistry.AudioProcess) {
        // Wall-clock around the HAL calls below.
        //
        // Between an application starting to play and MixPill's fader
        // controlling it, two things can be slow and they need opposite
        // responses: this queue waiting its turn, or `coreaudiod` taking
        // its time. Only a timestamp on both sides can tell them apart, and
        // on 2026-08-10 that distinction was the whole answer. Opening one
        // tap took **120 s**, in four clean 30-second steps — the HAL's
        // client-to-daemon timeout, once per property call on the new
        // aggregate — on a machine carrying seven third-party CoreAudio
        // drivers. The same sequence from a standalone command-line tool,
        // run at the same moment, took 101 s; the very next tap MixPill
        // opened took 0.03 s. So it is the daemon, not this code, and the
        // numbers below are what make that provable from a log instead of
        // arguable. They are also the first thing to read when someone
        // reports that MixPill "took ages to notice" an app: a large
        // `s in the HAL` is their audio stack, a large `waited` is ours.
        let startedAt = Date()
        // Capture as a stereo mixdown, and undo its attenuation.
        //
        // A device-format tap is exact but carries the device's full width:
        // on a 64-channel interface that is 64 channels of IPC from
        // coreaudiod per app per I/O cycle, of which 62 are silence. With
        // three apps tapped that measured as ~37 MB/s crossing the HAL
        // proxy, and CoreAudio answered with
        // `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload`
        // — the intermittent clicking.
        //
        // The mixdown asks for two channels instead, cutting that by the
        // same factor it attenuates by. And it attenuates predictably: it
        // averages across the device's channels, so audio in one pair of 64
        // arrives at exactly 1/32. Measured 32.0× on an Antelope Orion 32+,
        // matching channels/2 precisely. Multiplying back recovers the
        // original level, and on an ordinary stereo Mac the factor is 1 and
        // nothing happens at all.
        let deviceUID = registry.defaultOutputDeviceUID()
        let deviceChannels = deviceUID.map { registry.channelCount(forUID: $0) } ?? 2
        let rawCompensation = Float(max(1, deviceChannels / 2))
        let compensation = min(rawCompensation, Self.maximumMixdownCompensation)
        if rawCompensation > Self.maximumMixdownCompensation {
            MixPillCoreLog.log("ProcessTapCapture: mixdown compensation ×\(rawCompensation) exceeds the verified ceiling; clamping to ×\(compensation)")
        }

        func makeDescription(stereoMixdown: Bool) -> CATapDescription {
            let description: CATapDescription
            if stereoMixdown {
                description = CATapDescription(stereoMixdownOfProcesses: process.objectIDs)
            } else if let deviceUID, !deviceUID.isEmpty {
                // Fallback: the device's own format. Exact, just expensive.
                description = CATapDescription(
                    __processes: process.objectIDs.map { NSNumber(value: $0) },
                    andDeviceUID: deviceUID,
                    withStream: 0
                )
            } else {
                description = CATapDescription(stereoMixdownOfProcesses: process.objectIDs)
            }
            description.name = "MixPill — \(process.name)"
            description.uuid = UUID()
            // Private: the tap belongs to this process and never appears in
            // other apps' device lists or in Audio MIDI Setup.
            description.isPrivate = true
            // The reason there is no driver: macOS mutes the app's own output
            // while we hold the tap, so our processed copy is the only one
            // the user hears.
            description.muteBehavior = .mutedWhenTapped
            return description
        }

        // Prefer the cheap stereo mixdown; fall back to the device's own
        // format if this device will not give us one.
        var description = makeDescription(stereoMixdown: true)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapClock = Date()
        var tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        let tapSeconds = Date().timeIntervalSince(tapClock)

        if tapStatus != noErr || tapID == kAudioObjectUnknown, deviceUID != nil {
            MixPillCoreLog.log("ProcessTapCapture: stereo tap unavailable for \(process.bundleID) (status \(tapStatus)); falling back to the device format")
            description = makeDescription(stereoMixdown: false)
            tapID = kAudioObjectUnknown
            tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        }

        guard tapStatus == noErr, tapID != kAudioObjectUnknown else {
            MixPillCoreLog.log("ProcessTapCapture: could not tap \(process.bundleID) (status \(tapStatus))")
            recordFailure(process: process, status: tapStatus)
            return
        }

        guard let format = tapFormat(of: tapID) else {
            MixPillCoreLog.log("ProcessTapCapture: no stream format for \(process.bundleID)")
            AudioHardwareDestroyProcessTap(tapID)
            recordFailure(process: process, status: kAudioHardwareUnspecifiedError)
            return
        }

        // The scratch is always stereo: whatever width the tap delivers, we
        // extract one pair from it.
        let tap = Tap(bundleID: process.bundleID, channels: 2, frames: Self.scratchFrames)
        tap.tapID = tapID
        tap.format = format
        tap.sourceChannelCount = max(1, Int(format.mChannelsPerFrame))
        if tap.sourceChannelCount > 2, let deviceUID {
            // Device-format fallback: pick the pair carrying the audio.
            let pair = registry.preferredStereoChannels(forUID: deviceUID)
            tap.sourceLeft = min(pair.left, tap.sourceChannelCount - 1)
            tap.sourceRight = min(pair.right, tap.sourceChannelCount - 1)
            tap.mixdownCompensation = 1
        } else {
            tap.sourceLeft = 0
            tap.sourceRight = min(1, tap.sourceChannelCount - 1)
            tap.mixdownCompensation = compensation
        }

        // A tap reaches a client through an aggregate device that lists it
        // as a sub-tap. No sub-devices: this aggregate exists purely to
        // carry the tap's input stream.
        let aggregateUID = "com.mixpill.tap.\(description.uuid.uuidString)"
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "MixPill \(process.name)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [[
                kAudioSubTapUIDKey as String: description.uuid.uuidString,
                // Drift compensation on, paired with the larger capture
                // block below.
                //
                // These two settings have to be chosen together. With the
                // old 256-frame capture block, compensation resynchronised
                // often enough to blow the deadline — one
                // `kAudioDeviceProcessorOverload` roughly every 15 seconds.
                // Turning it off cured that but let the tap's clock walk
                // away from the output device's, which surfaced as the ring
                // overflowing and discarding blocks: a different click for
                // the same reason. A 1024-frame block gives compensation
                // the room it needs, so the clocks stay locked and nothing
                // is thrown away.
                kAudioSubTapDriftCompensationKey as String: true,
            ]],
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggregateClock = Date()
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        let aggregateSeconds = Date().timeIntervalSince(aggregateClock)
        guard aggregateStatus == noErr, aggregateID != kAudioObjectUnknown else {
            MixPillCoreLog.log("ProcessTapCapture: aggregate failed for \(process.bundleID) (status \(aggregateStatus))")
            AudioHardwareDestroyProcessTap(tapID)
            recordFailure(process: process, status: aggregateStatus)
            return
        }
        tap.aggregateID = aggregateID

        // Give the capture side a larger I/O block than playback.
        //
        // Latency here is absorbed by the ring, and the deadline pressure
        // that causes `skipping cycle due to overload` scales with how
        // often the cycle runs. Playback still runs at 256 frames, so the
        // mixer's own contribution to latency is unchanged.
        var captureFrames = captureBufferFrames
        var frameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let frameStatus = AudioObjectSetPropertyData(
            aggregateID, &frameAddress, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &captureFrames
        )
        if frameStatus != noErr {
            MixPillCoreLog.log("ProcessTapCapture: could not set capture block size (status \(frameStatus))")
        }

        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { [weak self, weak tap] _, inputData, _, _, _ in
            guard let self, let tap else { return }
            self.consume(inputData, into: tap)
        }
        guard ioStatus == noErr, let ioProcID else {
            MixPillCoreLog.log("ProcessTapCapture: IOProc failed for \(process.bundleID) (status \(ioStatus))")
            AudioHardwareDestroyAggregateDevice(aggregateID)
            AudioHardwareDestroyProcessTap(tapID)
            recordFailure(process: process, status: ioStatus)
            return
        }
        tap.ioProcID = ioProcID

        // CoreAudio tells us when it could not deliver a block in time.
        // That is precisely a dropout, reported by the system rather than
        // inferred, so it costs nothing to listen and answers "was that a
        // glitch or my ears?" definitively.
        observeOverload(on: aggregateID, label: process.name)

        // Publish before starting: the IOProc can fire immediately.
        lock.withLockVoid { taps[process.bundleID] = tap }

        let startClock = Date()
        let startStatus = AudioDeviceStart(aggregateID, ioProcID)
        let startSeconds = Date().timeIntervalSince(startClock)
        guard startStatus == noErr else {
            MixPillCoreLog.log("ProcessTapCapture: start failed for \(process.bundleID) (status \(startStatus))")
            performStop(bundleID: process.bundleID)
            recordFailure(process: process, status: startStatus)
            return
        }

        // Record what the device actually gave us — the request can be
        // clamped, and a block size we did not get is a block size we
        // cannot reason about.
        var actualFrames: UInt32 = 0
        var actualSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(aggregateID, &frameAddress, 0, nil, &actualSize, &actualFrames)
        if actualFrames > 0 {
            var timebase = mach_timebase_info()
            if mach_timebase_info(&timebase) == KERN_SUCCESS, timebase.numer > 0 {
                let seconds = Double(actualFrames) / max(format.mSampleRate, 1)
                let ticks = seconds * 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer)
                tap.expectedInterval = UInt64(ticks)
            }
        }

        captureState.failures.removeValue(forKey: process.bundleID)

        // A tapped app is muted at source, so it needs somewhere for its
        // audio to land before the interface gets around to describing the
        // channel.
        mixer.ensureStrip(for: process.bundleID)

        let elapsed = Date().timeIntervalSince(startedAt)
        MixPillCoreLog.log("ProcessTapCapture: tapped \(process.bundleID) — \(process.objectIDs.count) process object(s), \(Int(format.mSampleRate)) Hz, \(tap.sourceChannelCount) ch, ×\(tap.mixdownCompensation) compensation, \(actualFrames == 0 ? captureBufferFrames : actualFrames)-frame blocks, \(String(format: "%.2f", elapsed)) s in the HAL (tap \(String(format: "%.2f", tapSeconds)) s, aggregate \(String(format: "%.2f", aggregateSeconds)) s, start \(String(format: "%.2f", startSeconds)) s)")
    }

    private func recordFailure(process: AudioProcessRegistry.AudioProcess, status: OSStatus) {
        displayNames[process.bundleID] = process.name
        captureState.failures[process.bundleID] = status
    }

    private func performStop(bundleID: String) {
        let tap = lock.withLock { taps.removeValue(forKey: bundleID) }
        guard let tap else { return }

        if let ioProcID = tap.ioProcID, tap.aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(tap.aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(tap.aggregateID, ioProcID)
        }
        if tap.aggregateID != kAudioObjectUnknown {
            removeOverloadListener(from: tap.aggregateID)
            AudioHardwareDestroyAggregateDevice(tap.aggregateID)
        }
        if tap.tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap.tapID)
        }

        MixPillCoreLog.log("ProcessTapCapture: released \(bundleID)")
    }

    /// Watches one device for `kAudioDeviceProcessorOverload`.
    ///
    /// The block is retained so it can be taken off again: aggregate
    /// devices come and go on every device change, wake and Ultra-Low
    /// Latency toggle, and a listener left behind on each one accumulates
    /// for as long as the service lives — which is longer than the UI.
    private func observeOverload(on deviceID: AudioObjectID, label: String) {
        guard overloadListeners[deviceID] == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MixPillCoreLog.log("Overload: capture IO for \(label) missed its deadline — this is an audible dropout")
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, overloadQueue, block) == noErr else { return }
        overloadListeners[deviceID] = block
    }

    private func removeOverloadListener(from deviceID: AudioObjectID) {
        guard let block = overloadListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, overloadQueue, block)
    }

    /// The tap's stream format, as the raw description.
    ///
    /// Deliberately not wrapped in `AVAudioFormat`: that initializer
    /// returns nil for any layout wider than stereo unless it is handed an
    /// explicit `AVAudioChannelLayout`, so on a 64-channel interface every
    /// tap looked like it had "no stream format" and capture went silent.
    /// Channel count and sample rate are all this needs.
    private func tapFormat(of tapID: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioProcessRegistry.address(kAudioTapPropertyFormat)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &description) == noErr,
              description.mChannelsPerFrame > 0 else { return nil }
        return description
    }

    // MARK: - Capture path (real-time thread)

    /// Called on the aggregate device's IO thread. Everything here is
    /// preallocated: deinterleave into the tap's scratch, meter it, hand
    /// it to the ring. No allocation, no locks beyond two uncontended
    /// spins, no Obj-C.
    private func consume(_ inputData: UnsafePointer<AudioBufferList>, into tap: Tap) {
        // Timing first: a block that arrives late is a gap in the audio
        // whether or not anything downstream notices.
        let now = mach_absolute_time()
        if tap.lastCallbackHostTime != 0, tap.expectedInterval != 0 {
            let elapsed = now &- tap.lastCallbackHostTime
            // 1.8x leaves room for ordinary scheduling jitter while still
            // catching a genuinely missed cycle.
            if elapsed > tap.expectedInterval * 18 / 10 {
                tap.lateCallbacks.add(1, ordering: .relaxed)
            }
        }
        tap.lastCallbackHostTime = now

        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard buffers.count > 0 else { return }

        guard let left = tap.scratch[0], let right = tap.scratch[1] else { return }

        // Pull this app's stereo pair out of however wide the tap is. On a
        // 64-channel desk that means two strided reads out of 64; on a
        // laptop it is a plain copy.
        var frames = 0
        if buffers.count > 1 {
            // Deinterleaved: one buffer per channel.
            frames = min(Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size, tap.scratchFrames)
            guard frames > 0 else { return }
            copyPlane(from: buffers, channel: tap.sourceLeft, to: left, frames: frames)
            copyPlane(from: buffers, channel: tap.sourceRight, to: right, frames: frames)
        } else {
            guard let interleaved = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            let stride = max(1, Int(buffers[0].mNumberChannels))
            let totalFloats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            frames = min(totalFloats / stride, tap.scratchFrames)
            guard frames > 0 else { return }

            if stride == 2 {
                var split = DSPSplitComplex(realp: left, imagp: right)
                interleaved.withMemoryRebound(to: DSPComplex.self, capacity: frames) { source in
                    vDSP_ctoz(source, 2, &split, 1, vDSP_Length(frames))
                }
            } else {
                deinterleave(interleaved, channel: min(tap.sourceLeft, stride - 1), stride: stride, to: left, frames: frames)
                deinterleave(interleaved, channel: min(tap.sourceRight, stride - 1), stride: stride, to: right, frames: frames)
            }
        }

        // Undo the mixdown's averaging before anything measures or mixes it.
        if tap.mixdownCompensation != 1 {
            var gain = tap.mixdownCompensation
            vDSP_vsmul(left, 1, &gain, left, 1, vDSP_Length(frames))
            vDSP_vsmul(right, 1, &gain, right, 1, vDSP_Length(frames))
        }

        meter(tap: tap, channels: 2, frames: frames)
        mixer.writeCapturedFrames(tap.scratch, sourceChannels: 2, frames: frames, forBundleID: tap.bundleID)
    }

    /// Strided single-channel extraction. `vDSP_mmov` treats the block as a
    /// matrix and lifts one column out in a single vectorized pass —
    /// `cblas_scopy` would do the same but is deprecated.
    @inline(__always)
    private func deinterleave(_ source: UnsafePointer<Float>, channel: Int, stride: Int,
                              to destination: UnsafeMutablePointer<Float>, frames: Int) {
        vDSP_mmov(source + channel, destination, 1, vDSP_Length(frames), vDSP_Length(stride), 1)
    }

    @inline(__always)
    private func copyPlane(from buffers: UnsafeMutableAudioBufferListPointer, channel: Int,
                           to destination: UnsafeMutablePointer<Float>, frames: Int) {
        let index = min(channel, buffers.count - 1)
        guard let source = buffers[index].mData else {
            vDSP_vclr(destination, 1, vDSP_Length(frames))
            return
        }
        memcpy(destination, source, frames * MemoryLayout<Float>.size)
    }

    private func meter(tap: Tap, channels: Int, frames: Int) {
        var rms: Float = 0
        var peak: Float = 0
        for channel in 0..<channels {
            guard let data = tap.scratch[channel] else { continue }
            var channelRMS: Float = 0
            vDSP_rmsqv(data, 1, &channelRMS, vDSP_Length(frames))
            rms = max(rms, channelRMS)

            var channelPeak: Float = 0
            vDSP_maxmgv(data, 1, &channelPeak, vDSP_Length(frames))
            peak = max(peak, channelPeak)
        }

        tap.rmsBits.store(rms.bitPattern, ordering: .relaxed)
        tap.peakBits.store(peak.bitPattern, ordering: .relaxed)

        if !tap.hasLoggedFirstAudio && peak > 0.0001 {
            tap.hasLoggedFirstAudio = true
            MixPillCoreLog.log("ProcessTapCapture: first audio from \(tap.bundleID) (peak \(peak))")
        }
    }

    /// Reads the latest metering for every live tap.
    ///
    /// Called on the service queue, never on an audio thread — the audio
    /// side only ever stores into two atomics per tap.
    func drainLevels() -> [(bundleID: String, rms: Float, peak: Float)] {
        lock.withLock {
            taps.map { bundleID, tap in
                (bundleID: bundleID,
                 rms: Float(bitPattern: tap.rmsBits.load(ordering: .relaxed)),
                 peak: Float(bitPattern: tap.peakBits.load(ordering: .relaxed)))
            }
        }
    }
}
