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

    /// Ducking needs a steady pulse whether or not anyone is looking; the
    /// meters need enough frames to look like meters. 10 Hz costs nothing
    /// when idle, 30 Hz is where stepping stops being visible.
    private static let backgroundMeterInterval = 1.0 / 10.0
    private static let displayMeterInterval = 1.0 / 30.0

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
            let apps = processes.map {
                CoreAppInfo(bundleID: $0.bundleID, name: $0.name,
                            isPlaying: $0.isPlaying, isCapturingInput: $0.isCapturingInput)
            }
            self.ducking.updateCallParticipants(processes.filter(\.isCapturingInput).map(\.bundleID))
            self.sendToUI { proxy in
                if let data = MixPillCoder.encode(apps) {
                    proxy.appsChanged(data)
                }
            }
            self.capture.sync(with: processes)
        }

        resilience.currentProcessesProvider = { [weak self] in
            self?.discovery.currentProcesses ?? []
        }
        resilience.onRecovery = { [weak self] reason, date in
            self?.sendToUI { $0.recoveryOccurred(reason: reason, date: date) }
            self?.pushDevices()
        }

        capture.onAvailabilityChanged = { [weak self] available, reason in
            self?.sendToUI { $0.captureAvailabilityChanged(available: available, reason: reason) }
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
                let pairID = pairIndex == 0 ? device.uid : "\(device.uid)#\(pairIndex)"
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
            columns: columns
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
            if underruns > 0 || drops > 0 {
                MixPillCoreLog.log("RingHealth: \(underruns) underrun(s), \(drops) drop(s) in the last 5 s")
            }
        }
        timer.resume()
        ringHealthTimer = timer
    }

    /// Call on `queue`.
    private func applyMeterInterval() {
        let interval = meterDisplayActive ? Self.displayMeterInterval : Self.backgroundMeterInterval
        levelTimer?.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(meterDisplayActive ? 2 : 10)
        )
    }

    private func flushLevels() {
        let levels = capture.drainLevels()
        guard !levels.isEmpty else { return }

        // Ducking runs regardless of who is watching.
        ducking.evaluate(levels: levels)

        guard uiConnected else { return }

        let payload = LevelsPayload(samples: levels.map { sample in
            LevelSample(bundleID: sample.bundleID, rms: sample.rms, peak: sample.peak)
        })
        if let data = MixPillCoder.encode(payload) {
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
        let apps = discovery.currentApps
        if let data = MixPillCoder.encode(apps) {
            sendToUI { $0.appsChanged(data) }
        }
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

            // Strips may have arrived after their taps did, so re-run the
            // sync: it is idempotent, and this is the point where the
            // engine first knows what each application's settings are.
            self.capture.sync(with: self.discovery.currentProcesses)

            reply(true)
        }
    }

    func applyChannel(_ data: Data) {
        guard let config = MixPillCoder.decode(ChannelConfig.self, from: data) else { return }
        queue.async {
            self.mixer.applyChannel(config)
        }
    }

    func removeChannel(_ bundleID: String) {
        queue.async {
            self.mixer.removeChannel(bundleID)
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
            snapshot.activeConverters = AudioResamplerService.shared.activeConverterCount
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
