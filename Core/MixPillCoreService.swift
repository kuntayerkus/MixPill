import Foundation

/// The MixPillCore XPC service facade. Owns every audio subsystem and
/// implements the UI-facing control protocol. Design rules:
///
/// - The UI sends *desired state*; the core owns *runtime state*.
/// - If the UI disconnects or crashes, nothing here stops: capture, mixing
///   and playback continue with the last received configuration.
/// - Events (app list, levels, devices, driver status, recoveries) are
///   pushed to whatever UI is connected; with none connected they are
///   simply dropped.
final class MixPillCoreService: NSObject, NSXPCListenerDelegate, MixPillCoreControlProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mixpill.core.service", qos: .userInteractive)

    private let registry = DeviceRegistry()
    private let mixer: LowLatencyMixerEngine
    private let capture: ProcessTapCapture
    private let ducking: DuckingController
    private let resilience: CoreResilienceEngine
    private let discovery: AudioProcessRegistry

    private var levelTimer: DispatchSourceTimer?
    private var uiConnected = false
    private var meterDisplayActive = false
    private var ringHealthTimer: DispatchSourceTimer?
    private var lastRingHealth: (underruns: Int, drops: Int) = (0, 0)
    private var lastLateCallbacks = 0
    /// What the interface has said about each channel's DAW Direct state.
    /// Absence matters as much as the value: an app that is not in here has
    /// not been described yet, and a recognised DAW stays untapped until it
    /// is.
    private var channelBypass: [String: Bool] = [:]

    private var untappedBundleIDs: Set<String> {
        Set(channelBypass.filter(\.value).keys)
    }

    /// Ducking needs a steady pulse whether or not anyone is looking; the
    /// meters need enough frames to look like meters. 10 Hz costs nothing
    /// when idle, 30 Hz is where stepping stops being visible.
    private static let backgroundMeterInterval = 1.0 / 10.0
    private static let displayMeterInterval = 1.0 / 30.0
    /// With no taps open there is nothing to meter and nothing to duck, so
    /// the pulse drops to a heartbeat rather than running ten times a
    /// second for the life of the machine.
    private static let idleMeterInterval = 1.0

    /// Last values sent per app, so unchanged levels are not re-encoded and
    /// shipped across XPC thirty times a second.
    private var lastSentLevels: [String: (rms: Float, peak: Float)] = [:]
    /// Below this difference a change is not visible on a 6 pt meter.
    private static let levelEpsilon: Float = 0.002

    private let proxyLock = UnfairLock()
    private var uiProxy: MixPillCoreEventsProtocol?

    override init() {
        mixer = LowLatencyMixerEngine(registry: registry)
        capture = ProcessTapCapture(mixer: mixer, registry: registry)
        ducking = DuckingController(mixer: mixer)
        resilience = CoreResilienceEngine(registry: registry, mixer: mixer, capture: capture)
        discovery = AudioProcessRegistry(excludedBundleIDs: [
            "com.mixpill.app",
            MixPillXPC.coreBundleIdentifier
        ])
        super.init()

        discovery.onProcessesChanged = { [weak self] processes in
            guard let self else { return }
            self.ducking.updateCallParticipants(processes.filter(\.isCapturingInput).map(\.bundleID))
            self.pushApps(processes)
            self.capture.sync(with: processes)
        }

        resilience.currentProcessesProvider = { [weak self] in
            self?.discovery.currentProcesses ?? []
        }
        resilience.onRecovery = { [weak self] reason, date in
            self?.sendToUI { $0.recoveryOccurred(reason: reason, date: date) }
            self?.pushDevices()
        }

        capture.currentProcessesProvider = { [weak self] in
            self?.discovery.currentProcesses ?? []
        }
        capture.onCaptureStateChanged = { [weak self] state in
            guard let self else { return }
            // Which apps are captured is part of what the interface draws
            // for each row, so the list has to go out again alongside the
            // banner.
            self.pushApps()
            // A tap opening or closing changes whether there is anything to
            // meter at all.
            self.queue.async { self.applyMeterInterval() }
            self.sendToUI {
                $0.captureAvailabilityChanged(
                    available: state.failures.isEmpty,
                    reason: Self.captureFailureMessage(for: state)
                )
            }
        }

        registry.changeQueue = queue
        registry.addObserver { [weak self] in
            self?.pushDevices()
        }
    }

    /// Boots subsystems. Called once from `main` before the listener
    /// resumes; audio-relevant state arrives later with the UI's
    /// configuration snapshot.
    ///
    /// Capture starts as soon as the HAL reports applications — there is
    /// no permission gate to wait behind any more, and no reason to keep
    /// audio silent until a UI happens to attach.
    func bootstrap() {
        resilience.start()
        discovery.start()
        startLevelTimer()
        startRingHealthProbe()
        MixPillCoreLog.log("MixPillCore: service bootstrapped")
    }

    // MARK: - UI event plumbing

    private func sendToUI(_ body: @escaping (MixPillCoreEventsProtocol) -> Void) {
        let proxy = proxyLock.withLock { uiProxy }
        guard let proxy else { return }
        body(proxy)
    }

    /// Sends the current application list, stamped with whether the engine
    /// actually holds a tap on each one.
    ///
    /// Callers that already hold a snapshot pass it in: the discovery
    /// callback delivers one, and re-reading it there would mean asking the
    /// discovery queue for a value while running on that very queue.
    private func pushApps(_ processes: [AudioProcessRegistry.AudioProcess]? = nil) {
        let captured = capture.capturedBundleIDs
        let apps = (processes ?? discovery.currentProcesses).map {
            CoreAppInfo(
                bundleID: $0.bundleID,
                name: $0.name,
                isPlaying: $0.isPlaying,
                isCapturingInput: $0.isCapturingInput,
                isCaptured: captured.contains($0.bundleID)
            )
        }
        guard let data = MixPillCoder.encode(apps) else { return }
        sendToUI { $0.appsChanged(data) }
    }

    /// Names the applications the engine could not tap, with the OSStatus
    /// the HAL actually returned. Vague is useless here — the whole point
    /// of reporting observed failures is that they can be looked up.
    private static func captureFailureMessage(for state: ProcessTapCapture.CaptureState) -> String {
        guard !state.failureNames.isEmpty else { return "" }
        let codes = Set(state.failures.values).sorted().map(String.init).joined(separator: ", ")
        let names = state.failureNames.joined(separator: ", ")
        let subject = state.failureNames.count == 1 ? "an audio tap" : "audio taps"
        return "macOS refused \(subject) on \(names) (error \(codes)). Retrying."
    }

    private func pushDevices() {
        let snapshot = registry.snapshot()

        var columns: [RoutingColumnDTO] = [RoutingColumnDTO(pairID: "system-default", displayName: "System Default")]
        for device in snapshot.devices {
            let pairCount = max(1, device.channelCount / 2)
            for pairIndex in 0..<pairCount {
                let channelLabel = pairCount > 1
                    ? "Outputs \(pairIndex * 2 + 1)-\(pairIndex * 2 + 2)"
                    : nil
                let displayName = channelLabel.map { "\(device.name) — \($0)" } ?? device.name
                // Built through the key type so the string the interface
                // compares against and the string the engine parses can never
                // drift apart.
                let pairID = MixEngineKey(deviceUID: device.uid, pairIndex: pairIndex).pairID
                columns.append(RoutingColumnDTO(
                    pairID: pairID,
                    displayName: displayName,
                    deviceName: device.name,
                    channelLabel: channelLabel
                ))
            }
        }

        let payload = DevicesPayload(
            devices: snapshot.devices.map { OutputDeviceDTO(uid: $0.uid, name: $0.name, channelCount: $0.channelCount) },
            defaultDeviceUID: snapshot.defaultDeviceUID,
            columns: columns,
            canonicalSampleRate: AudioResamplerService.canonicalFormat.sampleRate
        )
        if let data = MixPillCoder.encode(payload) {
            sendToUI { $0.devicesChanged(data) }
        }

    }

    /// Starts the metering pulse and leaves it running for the life of the
    /// service.
    ///
    /// It used to be suspended whenever no UI was attached, which quietly
    /// disabled Smart Ducking the moment the menu bar app quit — the one
    /// situation the whole XPC split exists to survive. The rate changes
    /// instead of the timer stopping.
    private func startLevelTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            self?.flushLevels()
        }
        levelTimer = timer
        applyMeterInterval()
        timer.resume()
    }

    /// Reports ring underruns and drops once every 5 seconds while they are
    /// happening. Both are audible as clicks, and a rate is far more useful
    /// than a total when chasing one down.
    private func startRingHealthProbe() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let health = self.mixer.ringHealth()
            let underruns = health.underruns - self.lastRingHealth.underruns
            let drops = health.drops - self.lastRingHealth.drops
            self.lastRingHealth = health
            let late = self.capture.lateCallbackCount - self.lastLateCallbacks
            self.lastLateCallbacks += late
            if underruns > 0 || drops > 0 || late > 0 {
                MixPillCoreLog.log("Health: \(late) late capture block(s), \(underruns) underrun(s), \(drops) drop(s) in the last 5 s")
                for entry in self.mixer.ringDetail() where entry.drops > 0 || entry.underruns > 0 {
                    MixPillCoreLog.log("  \(entry.bundleID): \(entry.filled)/\(entry.capacity) frames buffered, rendered=\(entry.rendered), \(entry.underruns) underrun / \(entry.drops) drop total")
                }
            }
        }
        timer.resume()
        ringHealthTimer = timer
    }

    /// Call on `queue`.
    private func applyMeterInterval() {
        let interval: Double
        if capture.activeTapCount == 0 {
            interval = Self.idleMeterInterval
        } else {
            interval = meterDisplayActive ? Self.displayMeterInterval : Self.backgroundMeterInterval
        }
        levelTimer?.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(meterDisplayActive ? 2 : 10)
        )
    }

    private func flushLevels() {
        let levels = capture.drainLevels()

        if levels.isEmpty {
            // Nothing tapped: fall back to the heartbeat and stop paying
            // for a ten-times-a-second wake-up that has nothing to report.
            if !lastSentLevels.isEmpty {
                lastSentLevels.removeAll()
            }
            applyMeterInterval()
            return
        }

        // Ducking runs regardless of who is watching.
        ducking.evaluate(levels: levels)

        guard uiConnected else { return }

        // Only apps whose level actually moved. A quiet app reports the
        // same value forever, and re-encoding it thirty times a second is
        // pure XPC traffic for a meter that will not change a pixel.
        var changed: [LevelSample] = []
        var live = Set<String>()
        for sample in levels {
            live.insert(sample.bundleID)
            let previous = lastSentLevels[sample.bundleID]
            let moved = previous.map {
                abs($0.rms - sample.rms) > Self.levelEpsilon || abs($0.peak - sample.peak) > Self.levelEpsilon
            } ?? true
            guard moved else { continue }
            lastSentLevels[sample.bundleID] = (sample.rms, sample.peak)
            changed.append(LevelSample(bundleID: sample.bundleID, rms: sample.rms, peak: sample.peak))
        }
        lastSentLevels = lastSentLevels.filter { live.contains($0.key) }

        guard !changed.isEmpty else { return }
        if let data = MixPillCoder.encode(LevelsPayload(samples: changed)) {
            sendToUI { $0.levelsChanged(data) }
        }
    }

    private func setUIConnected(_ connected: Bool) {
        queue.async {
            guard self.uiConnected != connected else { return }
            self.uiConnected = connected
            if !connected {
                // A departed UI cannot be watching meters.
                self.meterDisplayActive = false
                self.applyMeterInterval()
            }
        }
    }

    // MARK: - NSXPCListenerDelegate

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: MixPillCoreControlProtocol.self)
        connection.exportedObject = self
        connection.remoteObjectInterface = NSXPCInterface(with: MixPillCoreEventsProtocol.self)

        connection.invalidationHandler = { [weak self] in
            self?.proxyLock.withLockVoid { self?.uiProxy = nil }
            self?.setUIConnected(false)
            MixPillCoreLog.log("MixPillCore: UI disconnected — audio continues uninterrupted")
        }
        connection.interruptionHandler = {
            MixPillCoreLog.log("MixPillCore: UI connection interrupted; it will reconnect")
        }

        connection.resume()

        proxyLock.withLockVoid { uiProxy = connection.remoteObjectProxy as? MixPillCoreEventsProtocol }

        setUIConnected(true)

        // Resynchronize the freshly attached UI.
        sendToUI { $0.coreDidBecomeReady() }
        pushApps()
        pushDevices()

        MixPillCoreLog.log("MixPillCore: UI connected")
        return true
    }

    // MARK: - MixPillCoreControlProtocol

    func applyConfiguration(_ data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        guard let config = MixPillCoder.decode(EngineConfiguration.self, from: data) else {
            reply(false)
            return
        }

        queue.async {
            self.capture.setLowLatencyEnabled(config.lowLatencyEnabled)
            self.mixer.bootstrap(
                masterVolume: config.masterVolume,
                lowLatencyEnabled: config.lowLatencyEnabled
            )
            self.ducking.setEnabled(config.duckingEnabled)

            for channel in config.channels {
                self.mixer.applyChannel(channel)
            }
            for channel in config.channels {
                self.channelBypass[channel.bundleID] = channel.processingBypassed
            }
            // `setExcluded` re-runs the tap sync itself, so strips that
            // arrived after their taps did are picked up here — this is the
            // point where the engine first knows each app's settings.
            self.publishExclusions()

            reply(true)
        }
    }

    func applyChannel(_ data: Data) {
        guard let config = MixPillCoder.decode(ChannelConfig.self, from: data) else { return }
        queue.async {
            if self.applyLocked(config) {
                self.publishExclusions()
            }
        }
    }

    func applyChannels(_ data: Data) {
        guard let configs = MixPillCoder.decode([ChannelConfig].self, from: data) else { return }
        queue.async {
            var exclusionsChanged = false
            for config in configs where self.applyLocked(config) {
                exclusionsChanged = true
            }
            if exclusionsChanged {
                self.publishExclusions()
            }
        }
    }

    /// Applies one channel and reports whether it moved in or out of DAW
    /// Direct — which is the only part the capture layer needs to hear
    /// about. Call on `queue`.
    private func applyLocked(_ config: ChannelConfig) -> Bool {
        mixer.applyChannel(config)

        // DAW Direct means "do not touch this app at all", so a change to
        // it has to reach the capture layer, not just the DSP. The first
        // time we hear about a channel counts as a change even if the value
        // matches the default, because "described at all" is what releases
        // a recognised DAW from the untapped-by-default rule.
        let previous = channelBypass[config.bundleID]
        channelBypass[config.bundleID] = config.processingBypassed
        return previous != config.processingBypassed
    }

    /// Hands the capture layer both halves of the picture: which apps to
    /// leave alone, and which it has heard about at all. Call on `queue`.
    private func publishExclusions() {
        capture.setExcluded(untappedBundleIDs, configured: Set(channelBypass.keys))
    }

    func removeChannel(_ bundleID: String) {
        queue.async {
            self.mixer.removeChannel(bundleID)
            // The app is gone, so what the interface last said about it no
            // longer applies — if it comes back, it is undescribed again.
            self.channelBypass.removeValue(forKey: bundleID)
        }
    }

    func setMeterDisplayActive(_ active: Bool) {
        queue.async {
            guard self.meterDisplayActive != active else { return }
            self.meterDisplayActive = active
            self.applyMeterInterval()
        }
    }

    func setMasterVolume(_ volume: Float) {
        mixer.setMasterVolume(volume)
    }

    func setLowLatencyEnabled(_ enabled: Bool) {
        queue.async {
            self.capture.setLowLatencyEnabled(enabled)
            self.mixer.setLowLatencyEnabled(enabled)
            // The capture block size is fixed when a tap is created, so the
            // taps have to be rebuilt for the change to take effect.
            self.capture.restartAll(with: self.discovery.currentProcesses)
        }
    }

    func setDuckingEnabled(_ enabled: Bool) {
        ducking.setEnabled(enabled)
    }


    func setDefaultOutputDeviceUID(_ uid: String, reply: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            reply(self.registry.setDefaultOutputDevice(uid: uid))
        }
    }

    func requestDiagnostics(reply: @escaping @Sendable (Data) -> Void) {
        queue.async {
            var snapshot = DiagnosticsDTO()
            let mixerInfo = self.mixer.diagnostics()
            snapshot.engineHealthy = mixerInfo.healthy
            snapshot.ioBufferFrames = mixerInfo.ioBufferFrames
            snapshot.ioLatencyMS = mixerInfo.latencyMS
            snapshot.ringCapacityFrames = mixerInfo.ringCapacityFrames
            snapshot.activeTaps = self.capture.activeTapCount
            snapshot.activeEngines = mixerInfo.activeEngines
            snapshot.hardwareSampleRate = self.registry.defaultDeviceNominalSampleRate()
            snapshot.lastRecoveryReason = self.resilience.lastRecoveryReason
            snapshot.lastRecoveryDate = self.resilience.lastRecoveryDate

            reply(MixPillCoder.encode(snapshot) ?? Data())
        }
    }


    func performManualRecovery() {
        resilience.performManualRecovery()
    }
}
