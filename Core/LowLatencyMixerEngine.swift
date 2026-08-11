import Foundation
import CoreAudio
import AudioUnit
import AVFoundation
import Accelerate
import Synchronization

/// One captured application: its ring buffer, inline DSP state, and the
/// engine it currently feeds.
final class ChannelStrip: @unchecked Sendable {
    let bundleID: String
    let ring: RingBufferManager
    let dsp: ChannelStripDSP
    /// The routing the UI asked for ("system-default" or a pair id).
    var desiredPairID: String
    /// The engine this strip currently feeds.
    var routingKey: MixEngineKey
    var eqGains: [Float]
    /// The last state reported to the log, so the line appears when
    /// something changed and not merely when a message arrived. The whole
    /// channel table is re-sent every time any application starts or stops
    /// playing, which is often enough to bury the signal. Control queue.
    var loggedState: String = ""

    /// Render scratch capacity, in frames.
    ///
    /// Allocated once at strip creation and **never** resized. The render
    /// callback reads these pointers with no synchronization, so freeing
    /// them under it — which resizing on reroute or on an engine rebuild
    /// used to do — is a use-after-free. Sized instead for any I/O block
    /// the HAL might plausibly hand us; `render` still bounds-checks.
    static let scratchFrames = 8192

    /// Stereo render scratch: two channel buffers plus the pointer vector
    /// the ring's raw-pointer read path consumes.
    let scratch: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>

    init(bundleID: String, ring: RingBufferManager, dsp: ChannelStripDSP, desiredPairID: String, routingKey: MixEngineKey, eqGains: [Float]) {
        self.bundleID = bundleID
        self.ring = ring
        self.dsp = dsp
        self.desiredPairID = desiredPairID
        self.routingKey = routingKey
        self.eqGains = eqGains

        scratch = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
        for channel in 0..<2 {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: Self.scratchFrames)
            buffer.initialize(repeating: 0, count: Self.scratchFrames)
            scratch[channel] = buffer
        }
    }

    deinit {
        for channel in 0..<2 {
            scratch[channel]?.deallocate()
        }
        scratch.deallocate()
    }
}

/// One AUHAL output unit: the physical (or default) device endpoint plus
/// the strips currently mixed into it.
final class DeviceOutputEngine: @unchecked Sendable {
    let key: MixEngineKey
    private(set) var unit: AudioUnit?
    private(set) var ioBufferFrames: UInt32 = 0
    private(set) var running = false
    /// Canonical rate captured at start; the render path reads this stored
    /// value and never touches the resampler (which is lock-protected).
    private(set) var sampleRate: Double = CoreAudioFormat.baseSampleRate

    /// Strips rendered by the callback, observed lock-free.
    let stripList: RTParameterStore<[Unmanaged<ChannelStrip>]>

    /// Master fader, applied to the summed mix. Mirrored onto every engine
    /// by `LowLatencyMixerEngine` so the render callback needs nothing but
    /// a relaxed atomic load.
    let masterGain = Atomic<Float>(1.0)

    /// The limiter's current gain, published for the interface.
    ///
    /// Without this the limiter is the one stage in the chain that can
    /// silently overrule the user: on a modern master peaking near full
    /// scale, half of a +6 dB channel boost is spent holding the sum under
    /// the ceiling, and the fader simply appears not to work. A render
    /// thread cannot say so — but it can store one float.
    let limiterGainBits = Atomic<UInt32>(Float(1.0).bitPattern)

    /// Set the first time this engine's render thread runs, so the Mach
    /// time-constraint policy is requested exactly once per thread.
    private let policyAttempted = Atomic<Bool>(false)

    private var accumulatorLeft: UnsafeMutablePointer<Float>?
    private var accumulatorRight: UnsafeMutablePointer<Float>?
    private var accumulatorCapacity: Int = 0
    /// Render-thread only: the output limiter's smoothed gain.
    private var limiterGain: Float = 1.0

    init(key: MixEngineKey) {
        self.key = key
        self.stripList = RTParameterStore(initial: [])
    }

    // MARK: Lifecycle (control queue)

    func start(deviceID: AudioDeviceID?, requestedBufferFrames: UInt32, sampleRate: Double, channelMap: [Int32]?) {
        self.sampleRate = sampleRate

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            MixPillCoreLog.log("DeviceOutputEngine: no HAL output component")
            return
        }

        var newUnit: AudioUnit?
        guard AudioComponentInstanceNew(component, &newUnit) == noErr, let unit = newUnit else {
            MixPillCoreLog.log("DeviceOutputEngine: could not instantiate HAL output unit")
            return
        }
        self.unit = unit

        if let deviceID {
            var target = deviceID
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &target,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                MixPillCoreLog.log("DeviceOutputEngine: could not pin device (status \(status))")
            }
        }

        // Client format: canonical Float32 stereo at the processing rate.
        // AUHAL converts to the device's native layout (including SRC and
        // interleaving) on its own, so a clock mismatch can never crash us.
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: UInt32(kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: CoreAudioFormat.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let formatStatus = AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input,
            0,
            &format,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        // Worth checking rather than assuming, because the failure mode is
        // invisible until it is expensive: if the client format does not
        // take, the render callback is handed the *device's* width instead
        // of stereo — 64 buffers per cycle on a large interface, 62 of them
        // existing only to be cleared. That is the shape of a deadline miss
        // that looks like it came from nowhere.
        if formatStatus != noErr {
            MixPillCoreLog.log("DeviceOutputEngine: client stream format rejected (status \(formatStatus)); the render callback will run at the device's width")
        }
        logRenderWidth(unit: unit)

        // Ask for the requested I/O block size; the device may clamp it.
        var frameSize = requestedBufferFrames
        AudioUnitSetProperty(
            unit,
            kAudioDevicePropertyBufferFrameSize,
            kAudioUnitScope_Global,
            0,
            &frameSize,
            UInt32(MemoryLayout<UInt32>.size)
        )
        var actualSize: UInt32 = 0
        var actualSizeBytes = UInt32(MemoryLayout<UInt32>.size)
        if AudioUnitGetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &actualSize, &actualSizeBytes) == noErr, actualSize > 0 {
            ioBufferFrames = actualSize
        } else {
            ioBufferFrames = requestedBufferFrames
        }

        if let channelMap {
            var map = channelMap
            let status = AudioUnitSetProperty(
                unit,
                kAudioOutputUnitProperty_ChannelMap,
                kAudioUnitScope_Global,
                0,
                &map,
                UInt32(MemoryLayout<Int32>.size * map.count)
            )
            if status != noErr {
                MixPillCoreLog.log("DeviceOutputEngine: could not apply channel map (status \(status))")
            }
        }

        var callback = AURenderCallbackStruct(
            inputProc: renderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        AudioUnitSetProperty(
            unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input,
            0,
            &callback,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )

        allocateAccumulator(capacity: Int(ioBufferFrames))

        guard AudioUnitInitialize(unit) == noErr else {
            MixPillCoreLog.log("DeviceOutputEngine: initialize failed")
            return
        }
        guard AudioOutputUnitStart(unit) == noErr else {
            MixPillCoreLog.log("DeviceOutputEngine: start failed")
            return
        }
        running = true
    }

    func stop() {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        running = false
    }

    /// Records how wide the render callback will actually be.
    ///
    /// The callback fills the unit's *input* scope, so that format — not the
    /// device's — decides how many buffers arrive per cycle and therefore
    /// how much of each block is spent clearing channels nobody asked for.
    /// Reading it back at start settles that from the HAL instead of from
    /// an assumption, and costs nothing on the audio thread.
    private func logRenderWidth(unit: AudioUnit) {
        func channels(_ scope: AudioUnitScope) -> UInt32? {
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, scope, 0, &description, &size) == noErr else { return nil }
            return description.mChannelsPerFrame
        }
        let client = channels(kAudioUnitScope_Input)
        let device = channels(kAudioUnitScope_Output)
        MixPillCoreLog.log("DeviceOutputEngine: render callback width \(client.map(String.init) ?? "unknown") channel(s), device presents \(device.map(String.init) ?? "unknown")")
    }

    private func allocateAccumulator(capacity: Int) {
        guard capacity > accumulatorCapacity else { return }
        freeAccumulator()
        let left = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        accumulatorLeft = left
        accumulatorRight = right
        accumulatorCapacity = capacity
    }

    private func freeAccumulator() {
        accumulatorLeft?.deallocate()
        accumulatorRight?.deallocate()
        accumulatorLeft = nil
        accumulatorRight = nil
        accumulatorCapacity = 0
    }

    // MARK: Render path (real-time audio thread)

    fileprivate func render(frameCount: Int, outputData: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard frameCount > 0 else { return noErr }
        if !policyAttempted.exchange(true, ordering: .relaxed) {
            RealtimeThread.applyTimeConstraintPolicy(bufferFrames: ioBufferFrames, sampleRate: sampleRate)
        }

        // Bail out to silence — not to stale buffer contents — if the HAL
        // asks for a block bigger than anything we sized storage for.
        guard let left = accumulatorLeft, let right = accumulatorRight,
              frameCount <= accumulatorCapacity, frameCount <= ChannelStrip.scratchFrames else {
            let abl = UnsafeMutableAudioBufferListPointer(outputData)
            for channel in 0..<abl.count {
                guard let data = abl[channel].mData else { continue }
                let floats = min(Int(abl[channel].mDataByteSize) / MemoryLayout<Float>.size, frameCount)
                vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1, vDSP_Length(floats))
            }
            return noErr
        }

        let frames = vDSP_Length(frameCount)
        vDSP_vclr(left, 1, frames)
        vDSP_vclr(right, 1, frames)

        let snapshot = stripList.load()
        snapshot.withUnsafeBufferPointer { buffer in
            for index in 0..<buffer.count {
                let strip = buffer[index].takeUnretainedValue()
                guard let stripLeft = strip.scratch[0], let stripRight = strip.scratch[1] else { continue }

                strip.ring.read(frameCount: frameCount, intoPlanar: strip.scratch, channelCount: 2)
                strip.dsp.process(left: stripLeft, right: stripRight, frameCount: frameCount, sampleRate: sampleRate)
                vDSP_vadd(stripLeft, 1, left, 1, left, 1, frames)
                vDSP_vadd(stripRight, 1, right, 1, right, 1, frames)
            }
        }

        // Master fader across the summed mix.
        var master = masterGain.load(ordering: .relaxed)
        if master != 1.0 {
            vDSP_vsmul(left, 1, &master, left, 1, frames)
            vDSP_vsmul(right, 1, &master, right, 1, frames)
        }

        limit(left: left, right: right, frames: frames)

        let abl = UnsafeMutableAudioBufferListPointer(outputData)
        if abl.count >= 2 {
            copyFrames(from: left, to: abl[0], frameCount: frameCount)
            copyFrames(from: right, to: abl[1], frameCount: frameCount)
            for channel in 2..<abl.count {
                if let data = abl[channel].mData {
                    vDSP_vclr(data.assumingMemoryBound(to: Float.self), 1, frames)
                }
            }
        } else if abl.count == 1 {
            // Mono endpoint: mix L+R at half gain.
            var half: Float = 0.5
            vDSP_vadd(left, 1, right, 1, left, 1, frames)
            vDSP_vsmul(left, 1, &half, left, 1, frames)
            copyFrames(from: left, to: abl[0], frameCount: frameCount)
        }

        return noErr
    }

    /// Holds the summed mix under full scale.
    ///
    /// The render pass adds channel strips together and applies the master
    /// fader; nothing between that and the hardware stopped the sum from
    /// exceeding ±1.0, so three apps playing loudly were hard-clipped by
    /// CoreAudio. The capture side makes it sharper still: a stereo mixdown
    /// on a wide interface is multiplied back up by as much as 32×, and a
    /// wrong guess there is a 30 dB step, not a subtle one.
    ///
    /// Block-rate detection with a fast attack, a slow release and a ramp
    /// inside the block — no allocation, no branch per sample. The final
    /// clip is the belt to the limiter's braces: the very first block of an
    /// unexpected transient can still poke through before the gain has
    /// moved, and clipping at exactly ±1.0 beats wrapping.
    private func limit(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: vDSP_Length) {
        var peakLeft: Float = 0
        var peakRight: Float = 0
        vDSP_maxmgv(left, 1, &peakLeft, frames)
        vDSP_maxmgv(right, 1, &peakRight, frames)
        let peak = max(peakLeft, peakRight)

        let target = peak > AudioScale.limiterCeiling ? AudioScale.limiterCeiling / peak : 1.0
        let coefficient = target < limiterGain
            ? AudioScale.limiterAttackCoefficient
            : AudioScale.limiterReleaseCoefficient

        let previous = limiterGain
        limiterGain += (target - limiterGain) * coefficient
        limiterGainBits.store(limiterGain.bitPattern, ordering: .relaxed)

        if previous != 1.0 || limiterGain != 1.0 {
            var step = (limiterGain - previous) / Float(frames)
            var leftStart = previous
            vDSP_vrampmul(left, 1, &leftStart, &step, left, 1, frames)
            var rightStart = previous
            vDSP_vrampmul(right, 1, &rightStart, &step, right, 1, frames)
        }

        var floor: Float = -1
        var ceiling: Float = 1
        vDSP_vclip(left, 1, &floor, &ceiling, left, 1, frames)
        vDSP_vclip(right, 1, &floor, &ceiling, right, 1, frames)
    }

    private func copyFrames(from source: UnsafePointer<Float>, to audioBuffer: AudioBuffer, frameCount: Int) {
        guard let destination = audioBuffer.mData else { return }
        let byteCount = min(Int(audioBuffer.mDataByteSize), frameCount * MemoryLayout<Float>.size)
        memcpy(destination, source, byteCount)
    }
}

/// C trampoline handed to CoreAudio; `refCon` is the owning engine.
private let renderCallback: AURenderCallback = { refCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
    guard let ioData else { return noErr }
    let engine = Unmanaged<DeviceOutputEngine>.fromOpaque(refCon).takeUnretainedValue()
    return engine.render(frameCount: Int(inNumberFrames), outputData: ioData)
}

/// The zero-latency mixing core. Replaces the old AVAudioEngine-based
/// graph with one raw AUHAL output unit per (device, channel pair) and a
/// single render callback that mixes every channel strip inline:
///
///   ring read → noise gate → 5-band biquad EQ → compressor → gain
///
/// All DSP runs in the render block on the real-time thread (vDSP only,
/// no allocation, no locks); parameters arrive through lock-free
/// `RTParameterStore` snapshots. Ring buffers are sized to comfortably hold
/// a capture block (see `minimumRingFrames`); since they drop oldest and
/// are drained every I/O cycle, pipeline latency is still dominated by the
/// hardware I/O block itself.
final class LowLatencyMixerEngine: @unchecked Sendable {
    static let standardBufferFrames: UInt32 = 256
    static let lowLatencyBufferFrames: UInt32 = 128

    /// Floor on ring capacity, in frames.
    ///
    /// The ring is sized against the **producer's** block, not ours.
    /// A tap's aggregate device hands us blocks sized by its own clock,
    /// which scales with the sample rate. A ring smaller than one producer block throws away part of
    /// every buffer it is handed — continuous dropouts, which is exactly
    /// what the old 384-frame floor did in low-latency mode.
    ///
    /// Capacity is a ceiling, not a target — but that only became true when
    /// `RingBufferManager` learned to steer its occupancy back down. Before
    /// that, headroom was latency waiting to happen: any stall filled the
    /// ring and it stayed filled, so a bigger ring bought a bigger permanent
    /// delay. Now the controller holds occupancy near the target regardless,
    /// and capacity buys exactly one thing: how long the output can be
    /// descheduled before frames start being discarded. At 48 kHz this is
    /// 683 ms, against the 170 ms that measured ~20 discarded blocks a
    /// second with every core spinning. It costs 256 KB per captured
    /// application and no latency at all.
    private static let minimumRingFrames = 32768

    private static func ringCapacity(for bufferFrames: UInt32) -> Int {
        max(minimumRingFrames, Int(bufferFrames) * 4)
    }

    private let queue = DispatchQueue(label: "com.mixpill.core.mixer", qos: .userInteractive)
    private let registryLock = UnfairLock()

    /// Lock-free view of `strips` for the capture threads.
    ///
    /// `writeCapturedFrames` runs on a tap's real-time IO thread. Looking a
    /// strip up under `registryLock` put that thread behind a lock the
    /// control queue also takes — and `allStrips()` *allocates an array*
    /// while holding it. Every engine rebuild, ducking decision and
    /// five-second health probe could therefore stall a capture callback
    /// past its deadline, which CoreAudio reports as
    /// `kAudioDeviceProcessorOverload` and the user hears as a click.
    ///
    /// The audio thread now reads an immutable snapshot through an atomic
    /// pointer instead: no lock to contend, nothing to allocate.
    private let stripSnapshot = RTParameterStore<[String: Unmanaged<ChannelStrip>]>(initial: [:])
    private let registry: DeviceRegistry

    private var engines: [MixEngineKey: DeviceOutputEngine] = [:]
    private var strips: [String: ChannelStrip] = [:]
    /// Strips removed from the mix are parked here so render-side
    /// unmanaged snapshots can never dangle. Bounded and tiny.
    private var retiredStrips: [ChannelStrip] = []
    private var lowLatencyEnabled = false
    private let masterVolume = Atomic<Float>(1.0)
    /// Last master gain written to the log; see `logApplied`. Control queue.
    private var loggedMasterVolume: Float = .nan
    /// Listener blocks by device, kept so they can be removed again.
    /// `AudioObjectRemovePropertyListenerBlock` matches on the block, and a
    /// bare `Set<AudioDeviceID>` also suppressed re-registration after a
    /// `coreaudiod` restart recycled an id onto a different device.
    private var overloadListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private let overloadQueue = DispatchQueue(label: "com.mixpill.core.overload.output", qos: .utility)
    /// Pending sweep for output units that no longer carry any strips.
    private var idleAudit: DispatchWorkItem?

    /// How long an output engine stays up after its last strip leaves.
    ///
    /// A running AUHAL holds its device awake. MixPill used to start one on
    /// the system default at boot and never stop it, so the output device
    /// never idled for as long as the app was installed — a measurable
    /// battery cost on a laptop, and on some interfaces an audible noise
    /// floor that simply never went away. The delay keeps a quick
    /// re-route from restarting hardware unnecessarily.
    private static let idleEngineGraceSeconds: Double = 5

    init(registry: DeviceRegistry) {
        self.registry = registry
    }

    // MARK: - Configuration (control queue entry points)

    func bootstrap(masterVolume: Float, lowLatencyEnabled: Bool) {
        queue.sync {
            self.masterVolume.store(masterVolume, ordering: .relaxed)
            self.lowLatencyEnabled = lowLatencyEnabled
            // No output unit is started here. Engines come up when a strip
            // needs one and go away again when the last one leaves, so an
            // idle MixPill lets the audio hardware sleep.
        }
    }

    /// `source` names the message that carried this value, and it is on
    /// the log line for one reason: a value arriving is not the same fact
    /// as a value *sticking*. When a fader stops working, the question is
    /// which of the interface's three routes — a single channel from a row,
    /// the whole table re-pushed after a discovery event, or a full
    /// configuration snapshot — wrote last.
    func applyChannel(_ config: ChannelConfig, source: String = "unspecified") {
        queue.sync { applyChannelLocked(config, source: source) }
    }

    /// Guarantees a strip exists for an application the capture layer has
    /// just tapped, without waiting for the interface to describe it.
    ///
    /// A tapped app is muted at source, so the window between "the tap
    /// opened" and "the UI told us what this channel should sound like"
    /// used to be a window of pure silence — most visible at launch, where
    /// discovery starts before the first configuration snapshot arrives and
    /// `writeCapturedFrames` had no strip to write into. A default strip
    /// costs one ring buffer and is overwritten milliseconds later by the
    /// real settings.
    func ensureStrip(for bundleID: String) {
        queue.async {
            guard self.strip(for: bundleID) == nil else { return }
            MixPillCoreLog.log("LowLatencyMixerEngine: default strip for \(bundleID) ahead of its configuration")
            self.applyChannelLocked(ChannelConfig(
                bundleID: bundleID,
                volume: CoreAudioFormat.defaultAppVolume,
                isMuted: false,
                eqGains: [0, 0, 0, 0, 0],
                processingBypassed: false,
                noiseGateThreshold: 0,
                compressorEnabled: false,
                routePairID: "system-default"
            ), source: "default")
        }
    }

    /// Call on `queue` only.
    private func applyChannelLocked(_ config: ChannelConfig, source: String = "unspecified") {
        let routingKey = resolveRouting(pairID: config.routePairID)

        if let existing = strip(for: config.bundleID) {
            updateStrip(existing, with: config, routingKey: routingKey, source: source)
            return
        }

        let ring = RingBufferManager(
            capacityFrames: Self.ringCapacity(for: requestedBufferFrames),
            channelCount: Int(CoreAudioFormat.channelCount)
        )
        let parameters = makeParameters(from: config)
        let strip = ChannelStrip(
            bundleID: config.bundleID,
            ring: ring,
            dsp: ChannelStripDSP(initial: parameters),
            desiredPairID: config.routePairID,
            routingKey: routingKey,
            eqGains: config.eqGains
        )

        registryLock.withLock { strips[config.bundleID] = strip }
        publishStripSnapshot()

        attach(strip, to: routingKey)
        logApplied(strip, source: source)
    }

    /// Records what the engine ended up applying, read back from the
    /// parameter block rather than from the configuration that set it.
    ///
    /// This is the externally visible half of the answer: the panel shows
    /// the same values live, but a log line can be read from outside the
    /// process, which is what makes "did that fader reach the engine?"
    /// measurable instead of arguable. Control queue.
    private func logApplied(_ strip: ChannelStrip, source: String) {
        let params = strip.dsp.parameters.load()
        let gain = params.isMuted ? 0 : params.volume * params.duckingTarget
        let state = "gain \(gain) (\(AudioScale.faderLabel(forGain: gain)))"
            + ", muted=\(params.isMuted)"
            + ", eq=\(params.eqEnabled ? strip.eqGains.description : "off")"
            + ", bypassed=\(params.processingBypassed)"
            + ", route=\(strip.desiredPairID), via \(source)"
        guard state != strip.loggedState else { return }
        strip.loggedState = state
        MixPillCoreLog.log("Applied \(strip.bundleID): \(state)")
    }

    func removeChannel(_ bundleID: String) {
        queue.sync {
            let strip = registryLock.withLock { strips.removeValue(forKey: bundleID) }
            guard let strip else { return }
            registryLock.withLock {
                retiredStrips.append(strip)
                if retiredStrips.count > 32 {
                    retiredStrips.removeFirst(retiredStrips.count - 32)
                }
            }

            publishStripSnapshot()
            strip.ring.reset()
            refreshStripList(for: strip.routingKey)
            scheduleIdleAudit()
        }
    }

    /// Rebuilds the lock-free lookup. Control queue only.
    private func publishStripSnapshot() {
        let snapshot = registryLock.withLock {
            strips.mapValues { Unmanaged.passUnretained($0) }
        }
        stripSnapshot.store(snapshot)
    }

    func setMasterVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        masterVolume.store(clamped, ordering: .relaxed)
        queue.async {
            self.publishMasterVolumeLocked(clamped)
        }
    }

    /// Mirrors the master fader onto every live output engine. Call on
    /// `queue` only — it walks the engine table.
    private func publishMasterVolumeLocked(_ volume: Float) {
        for (_, engine) in engines {
            engine.masterGain.store(volume, ordering: .relaxed)
        }
        if volume != loggedMasterVolume {
            loggedMasterVolume = volume
            MixPillCoreLog.log("Applied master: gain \(volume) (\(AudioScale.faderLabel(forGain: volume))) across \(engines.count) engine(s)")
        }
    }

    func setLowLatencyEnabled(_ enabled: Bool) {
        queue.sync {
            guard lowLatencyEnabled != enabled else { return }
            lowLatencyEnabled = enabled
            rebuildAllEnginesLocked()
        }
    }


    /// Smart Ducking entry point: sets the smoothed gain target for every
    /// strip except the VoIP apps themselves.
    func setDuckingMultiplier(_ multiplier: Float, excludingVoIP voipBundleIDs: Set<String>) {
        queue.sync {
            for strip in allStrips() where !voipBundleIDs.contains(strip.bundleID) {
                var params = strip.dsp.parameters.load()
                guard params.duckingTarget != multiplier else { continue }
                params.duckingTarget = multiplier
                strip.dsp.parameters.store(params)
            }
        }
    }

    // MARK: - Producer path (capture threads)

    /// Producer entry point for the tap IOProcs: planar float pointers
    /// straight from the capture thread's scratch, no buffer objects and
    /// no allocation on the way in.
    func writeCapturedFrames(
        _ sources: UnsafePointer<UnsafeMutablePointer<Float>?>,
        sourceChannels: Int,
        frames: Int,
        forBundleID bundleID: String
    ) {
        guard let handle = stripSnapshot.load()[bundleID] else { return }
        handle.takeUnretainedValue().ring.write(planar: sources, sourceChannels: sourceChannels, frames: frames)
    }

    // MARK: - Engine management (call on `queue` only)

    private var requestedBufferFrames: UInt32 {
        lowLatencyEnabled ? Self.lowLatencyBufferFrames : Self.standardBufferFrames
    }

    private func engine(for key: MixEngineKey) -> DeviceOutputEngine {
        if let existing = engines[key] { return existing }
        let engine = DeviceOutputEngine(key: key)
        // Engines are created lazily and after rebuilds, so seed the fader
        // before the unit starts rendering.
        engine.masterGain.store(masterVolume.load(ordering: .relaxed), ordering: .relaxed)
        startLocked(engine)
        engines[key] = engine
        return engine
    }

    private func startLocked(_ engine: DeviceOutputEngine) {
        let deviceID: AudioDeviceID? = engine.key.deviceUID.isEmpty
            ? nil
            : registry.deviceID(forUID: engine.key.deviceUID)

        // A pinned device that is gone stays gone: leave the engine
        // unstarted (its strips render silence) instead of silently
        // re-routing them to the default output. The next topology
        // recovery retries the start.
        if !engine.key.deviceUID.isEmpty && deviceID == nil {
            MixPillCoreLog.log("LowLatencyMixerEngine: device \(engine.key.deviceUID) not present; engine stays idle")
            return
        }

        var channelMap: [Int32]?
        if engine.key.pairIndex > 0, let uid = engine.key.deviceUID.isEmpty ? nil : engine.key.deviceUID {
            let deviceChannels = registry.channelCount(forUID: uid)
            let left = engine.key.pairIndex * 2
            let right = left + 1
            if right < deviceChannels {
                var map = [Int32](repeating: -1, count: deviceChannels)
                map[left] = 0
                map[right] = 1
                channelMap = map
            }
        }

        engine.start(
            deviceID: deviceID,
            requestedBufferFrames: requestedBufferFrames,
            sampleRate: AudioResamplerService.canonicalFormat.sampleRate,
            channelMap: channelMap
        )

        // The playback side can miss its deadline too, and when it does the
        // whole mix drops, not one app's.
        if let deviceID {
            observeOverload(on: deviceID, label: engine.key.deviceUID.isEmpty ? "system default" : engine.key.deviceUID)
        }
    }

    private func observeOverload(on deviceID: AudioDeviceID, label: String) {
        guard overloadListeners[deviceID] == nil else { return }
        var address = overloadAddress
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MixPillCoreLog.log("Overload: playback IO on \(label) missed its deadline — this is an audible dropout")
        }
        guard AudioObjectAddPropertyListenerBlock(deviceID, &address, overloadQueue, block) == noErr else { return }
        overloadListeners[deviceID] = block
    }

    private func removeOverloadListener(from deviceID: AudioDeviceID) {
        guard let block = overloadListeners.removeValue(forKey: deviceID) else { return }
        var address = overloadAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, overloadQueue, block)
    }

    private func removeAllOverloadListeners() {
        for deviceID in overloadListeners.keys {
            removeOverloadListener(from: deviceID)
        }
    }

    private var overloadAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDeviceProcessorOverload,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// Stops output units that no longer carry any strips, after a short
    /// grace period. Control queue.
    private func scheduleIdleAudit() {
        idleAudit?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopIdleEnginesLocked()
        }
        idleAudit = item
        queue.asyncAfter(deadline: .now() + Self.idleEngineGraceSeconds, execute: item)
    }

    private func stopIdleEnginesLocked() {
        let inUse = Set(allStrips().map(\.routingKey))
        for (key, engine) in engines where !inUse.contains(key) {
            engine.stop()
            engines.removeValue(forKey: key)
            if let deviceID = key.deviceUID.isEmpty ? nil : registry.deviceID(forUID: key.deviceUID) {
                removeOverloadListener(from: deviceID)
            }
            MixPillCoreLog.log("LowLatencyMixerEngine: released the idle output on \(key.deviceUID.isEmpty ? "system default" : key.deviceUID)")
        }
        if engines.isEmpty {
            // Nothing is routed anywhere; drop the default's listener too.
            removeAllOverloadListeners()
        }
    }

    private func attach(_ strip: ChannelStrip, to key: MixEngineKey) {
        strip.routingKey = key
        _ = engine(for: key)
        refreshStripList(for: key)
    }

    private func move(_ strip: ChannelStrip, to key: MixEngineKey) {
        let source = strip.routingKey
        strip.routingKey = key
        strip.ring.reset()
        _ = engine(for: key)
        // Drop the strip from its old engine before adding it to the new
        // one, so it is never rendered by both at once.
        refreshStripList(for: source)
        refreshStripList(for: key)
        scheduleIdleAudit()
    }

    private func refreshStripList(for key: MixEngineKey) {
        guard let engine = engines[key] else { return }
        let members = allStrips().filter { $0.routingKey == key }
        engine.stripList.store(members.map { Unmanaged.passUnretained($0) })
    }

    private func updateStrip(_ strip: ChannelStrip, with config: ChannelConfig, routingKey: MixEngineKey, source: String) {
        var params = strip.dsp.parameters.load()
        params.volume = config.volume
        params.isMuted = config.isMuted
        params.noiseGateThreshold = config.noiseGateThreshold
        params.compressorEnabled = config.compressorEnabled
        params.processingBypassed = config.processingBypassed

        // Bump the generation only when the *filter* changed.
        //
        // It used to be incremented on every write, so nudging a volume
        // slider made the render thread believe it had new coefficients and
        // reload them mid-callback. Worse, the whole channel table is
        // re-sent whenever any app starts or stops playing, so simply
        // opening a video in another window forced that reload on every
        // EQ-enabled strip.
        let sampleRate = AudioResamplerService.canonicalFormat.sampleRate
        if let coefficients = BiquadDesigner.peakingCoefficients(gains: config.eqGains, sampleRate: sampleRate) {
            if !params.eqEnabled || params.eqCoefficients != coefficients {
                params.eqCoefficients = coefficients
                params.generation &+= 1
            }
            params.eqEnabled = true
        } else {
            params.eqEnabled = false
        }
        strip.eqGains = config.eqGains
        strip.desiredPairID = config.routePairID
        strip.dsp.parameters.store(params)

        if routingKey != strip.routingKey {
            move(strip, to: routingKey)
        }
        logApplied(strip, source: source)
    }

    private func makeParameters(from config: ChannelConfig) -> ChannelDSPParameters {
        var params = ChannelDSPParameters.flat
        params.volume = config.volume
        params.isMuted = config.isMuted
        params.noiseGateThreshold = config.noiseGateThreshold
        params.compressorEnabled = config.compressorEnabled
        params.processingBypassed = config.processingBypassed
        params.generation = 1
        let sampleRate = AudioResamplerService.canonicalFormat.sampleRate
        if let coefficients = BiquadDesigner.peakingCoefficients(gains: config.eqGains, sampleRate: sampleRate) {
            params.eqEnabled = true
            params.eqCoefficients = coefficients
        }
        return params
    }

    /// Re-derives one strip's EQ for the current canonical rate, bumping the
    /// generation only if the coefficients actually moved. Control queue.
    private func refreshEQCoefficients(for strip: ChannelStrip) {
        var params = strip.dsp.parameters.load()
        let sampleRate = AudioResamplerService.canonicalFormat.sampleRate
        if let coefficients = BiquadDesigner.peakingCoefficients(gains: strip.eqGains, sampleRate: sampleRate) {
            if !params.eqEnabled || params.eqCoefficients != coefficients {
                params.eqCoefficients = coefficients
                params.generation &+= 1
            }
            params.eqEnabled = true
        } else {
            params.eqEnabled = false
        }
        strip.dsp.parameters.store(params)
    }

    private func resolveRouting(pairID: String) -> MixEngineKey {
        MixEngineKey.parse(pairID: pairID)
    }

    private func strip(for bundleID: String) -> ChannelStrip? {
        registryLock.withLock { strips[bundleID] }
    }

    private func allStrips() -> [ChannelStrip] {
        registryLock.withLock { Array(strips.values) }
    }

    // MARK: - Recovery

    /// Tears down every output unit and rebuilds them from scratch. Used
    /// after wake, after a `coreaudiod` restart, on canonical-rate
    /// changes, and by the Diagnostics reset. Old device IDs are untrusted
    /// in all of those situations, so engines re-resolve them on start.
    func rebuildAllEngines() {
        queue.sync {
            rebuildAllEnginesLocked()
        }
    }

    private func rebuildAllEnginesLocked() {
        idleAudit?.cancel()
        for (_, engine) in engines {
            engine.stop()
        }
        engines.removeAll()
        // Device ids are meaningless after a daemon restart, and a listener
        // registered against an old one has to come off before new ones go
        // on — otherwise a recycled id looks "already observed".
        removeAllOverloadListeners()

        for strip in allStrips() {
            strip.ring.reset()
            strip.dsp.resetTransientState()
            // EQ coefficients depend on the canonical rate; re-derive them.
            refreshEQCoefficients(for: strip)
        }

        // Recreate an engine for every routing target actually in use — and
        // only those, so a rebuild with nothing playing leaves the hardware
        // alone.
        let targets = Set(allStrips().map(\.routingKey))
        for target in targets {
            _ = engine(for: target)
        }
        for target in targets {
            refreshStripList(for: target)
        }
    }

    /// Best-effort teardown before system sleep.
    func stopAllEngines() {
        queue.sync {
            idleAudit?.cancel()
            for (_, engine) in engines {
                engine.stop()
            }
            engines.removeAll()
            removeAllOverloadListeners()
        }
    }

    /// Restarts any engine that is not running; returns overall health.
    ///
    /// Called by the resilience watchdog. It used to have no caller at all,
    /// while `CoreResilienceEngine` logged "watchdog will keep trying" after
    /// exhausting its `coreaudiod` retries — a promise nothing kept.
    @discardableResult
    func auditEngines() -> Bool {
        queue.sync {
            // No strips means nothing should be running; that is healthy.
            guard !allStrips().isEmpty else { return true }

            for (_, engine) in engines where !engine.running {
                MixPillCoreLog.log("LowLatencyMixerEngine: engine stalled, rebuilding all")
                rebuildAllEnginesLocked()
                return false
            }
            if engines.isEmpty {
                MixPillCoreLog.log("LowLatencyMixerEngine: strips with no output engine, rebuilding all")
                rebuildAllEnginesLocked()
                return false
            }
            return true
        }
    }

    // MARK: - Diagnostics

    /// How much gain the output limiter is currently taking off, in dB,
    /// across the busiest engine. Zero when it is not working.
    ///
    /// This is the missing half of "why did turning it up do nothing?".
    /// The limiter is doing exactly its job — the sum was already at the
    /// ceiling — but until the number is on screen the only visible fact is
    /// a fader that moved and a loudness that did not.
    func limiterReductionDB() -> Float {
        queue.sync {
            let gain = engines.values
                .filter(\.running)
                .map { Float(bitPattern: $0.limiterGainBits.load(ordering: .relaxed)) }
                .min() ?? 1
            guard gain < 1 else { return 0 }
            return -AudioScale.decibels(fromAmplitude: gain)
        }
    }

    /// What the render pass is actually applying, per channel.
    ///
    /// Read back from the same parameter blocks the render thread reads,
    /// not from the message that set them. Between a fader and the sound
    /// there is a preference file, an XPC hop, a decode and a parameter
    /// store; when the sound does not move, the only question worth asking
    /// is which of those the value stopped at, and nothing on the interface
    /// side can answer it.
    func appliedChannels() -> [AppliedChannelDTO] {
        allStrips()
            .map { strip in
                let params = strip.dsp.parameters.load()
                return AppliedChannelDTO(
                    bundleID: strip.bundleID,
                    appliedGain: params.isMuted ? 0 : params.volume * params.duckingTarget,
                    isMuted: params.isMuted,
                    eqEnabled: params.eqEnabled,
                    processingBypassed: params.processingBypassed
                )
            }
            .sorted { $0.bundleID < $1.bundleID }
    }

    /// Aggregate ring health across every strip.
    ///
    /// Starvations are reported alongside underruns rather than folded into
    /// them: a partial read is a hole in a stream that kept going, while a
    /// starvation is the stream stopping. Under load it is the second that
    /// dominates, and a single total would have hidden which one was
    /// happening.
    func ringHealth() -> (underruns: Int, starvations: Int, drops: Int, resyncs: Int) {
        allStrips().reduce(into: (0, 0, 0, 0)) { total, strip in
            total.0 += strip.ring.underruns
            total.1 += strip.ring.starvations
            total.2 += strip.ring.drops
            total.3 += strip.ring.resyncs
        }
    }

    /// The largest rate correction any live channel is applying, signed.
    /// Zero when nothing is playing.
    func clockCorrectionPPM() -> Int {
        allStrips()
            .filter(\.ring.isPrimed)
            .map(\.ring.rateCorrectionPPM)
            .max(by: { abs($0) < abs($1) }) ?? 0
    }

    /// Per-app ring state, for working out *which* channel is misbehaving
    /// rather than that some channel is.
    func ringDetail() -> [(bundleID: String, underruns: Int, starvations: Int, drops: Int, resyncs: Int, filled: Int, average: Int, ppm: Int, target: Int, capacity: Int, primed: Bool, rendered: Bool)] {
        queue.sync {
            let rendered = Set(engines.values.flatMap { engine -> [ObjectIdentifier] in
                let list = engine.stripList.load()
                return (0..<list.count).map { ObjectIdentifier(list[$0].takeUnretainedValue()) }
            })
            let consumerFrames = Int(engines[.systemDefault]?.ioBufferFrames
                ?? engines.values.first?.ioBufferFrames
                ?? requestedBufferFrames)
            return allStrips().map { strip in
                (strip.bundleID, strip.ring.underruns, strip.ring.starvations, strip.ring.drops,
                 strip.ring.resyncs, strip.ring.availableFrames, strip.ring.smoothedFill,
                 strip.ring.rateCorrectionPPM,
                 strip.ring.targetFrames(consumerFrames: consumerFrames),
                 strip.ring.capacity, strip.ring.isPrimed,
                 rendered.contains(ObjectIdentifier(strip)))
            }
        }
    }

    func diagnostics() -> (ioBufferFrames: Int, latencyMS: Double, ringCapacityFrames: Int, healthy: Bool, activeEngines: Int) {
        queue.sync {
            let frames = engines[.systemDefault]?.ioBufferFrames
                ?? engines.values.first?.ioBufferFrames
                ?? requestedBufferFrames
            let rate = AudioResamplerService.canonicalFormat.sampleRate
            // With nothing routed anywhere there is deliberately no output
            // unit running, and that is a healthy idle rather than a fault.
            let healthy = allStrips().isEmpty
                ? engines.isEmpty
                : (!engines.isEmpty && engines.values.allSatisfy(\.running))
            return (Int(frames), Double(frames) / rate * 1000.0, Self.ringCapacity(for: frames), healthy,
                    engines.values.filter(\.running).count)
        }
    }
}
