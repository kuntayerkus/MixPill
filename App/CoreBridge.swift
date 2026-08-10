import Foundation
import Observation

/// The UI's only door into the audio engine. Wraps the `NSXPCConnection`
/// to the MixPillCore service: pushes desired state outward, receives
/// observed reality inward, and reconnects transparently if the service
/// ever goes away.
///
/// UI crashes or quits never interrupt audio — the core keeps the last
/// configuration running — so this bridge optimizes for "reconnect and
/// resynchronize", never for "restart the engine".
@MainActor
@Observable
public final class CoreBridge: NSObject {
    public private(set) var isConnected = false
    public private(set) var routingColumns: [RoutingColumnDTO] = [
        RoutingColumnDTO(pairID: "system-default", displayName: "System Default")
    ]
    public private(set) var devices: [OutputDeviceDTO] = []
    public private(set) var defaultDeviceUID: String?

    /// Wired by `AppDiscoveryService`.
    var onAppsChanged: ((_ apps: [CoreAppInfo]) -> Void)?
    var onLevels: ((_ payload: LevelsPayload) -> Void)?
    /// Non-nil while the core cannot capture; carries the reason to show.
    public private(set) var captureProblem: String?
    var onRecovery: ((_ reason: String, _ date: Date) -> Void)?

    private var connection: NSXPCConnection?
    private var reconnectScheduled = false

    /// Applications the UI knows about, so a reconnect can resend every
    /// channel's desired state in one snapshot instead of relying on the
    /// next discovery event to refill the core.
    var knownBundleIDs: [String] = []

    // MARK: - Connection lifecycle

    /// Connects (idempotent) and pushes a full configuration snapshot.
    public func connect() {
        guard connection == nil else {
            pushConfiguration()
            return
        }

        // Bundled XPC service: looked up inside Contents/XPCServices, not in
        // the bootstrap namespace. launchd starts it on the first message.
        let newConnection = NSXPCConnection(serviceName: MixPillXPC.serviceName)
        newConnection.remoteObjectInterface = NSXPCInterface(with: MixPillCoreControlProtocol.self)
        newConnection.exportedInterface = NSXPCInterface(with: MixPillCoreEventsProtocol.self)
        newConnection.exportedObject = self

        newConnection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.connection = nil
                self?.isConnected = false
                self?.scheduleReconnect()
            }
        }
        newConnection.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.pushConfiguration()
            }
        }

        newConnection.resume()
        connection = newConnection
        // `isConnected` stays false until the core answers with
        // `coreDidBecomeReady()`. NSXPCConnection.resume() only arms the
        // connection — the service is not launched until the first message,
        // so claiming connectivity here would be a guess.
        pushConfiguration()
    }

    private func scheduleReconnect() {
        guard !reconnectScheduled else { return }
        reconnectScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            reconnectScheduled = false
            connect()
        }
    }

    /// Error handler for outgoing XPC messages. Deliberately a
    /// `nonisolated` function reference rather than an inline closure:
    /// NSXPCConnection calls it on its own queue, and an inline closure
    /// written here would inherit `@MainActor` isolation and trap.
    private nonisolated static func logXPCFailure(_ error: Error) {
        NSLog("MixPill: XPC message to MixPillCore failed: \(error)")
    }

    private var control: MixPillCoreControlProtocol? {
        connection?.remoteObjectProxyWithErrorHandler(CoreBridge.logXPCFailure) as? MixPillCoreControlProtocol
    }

    // MARK: - Desired state (UI → core)

    /// Full snapshot: sent on connect and whenever a global input changes
    /// (permission grant, Settings reset). The core applies it
    /// idempotently.
    public func pushConfiguration() {
        guard let control else { return }
        let store = ChannelConfigStore.shared
        let configuration = EngineConfiguration(
            masterVolume: store.masterVolume,
            lowLatencyEnabled: store.lowLatencyEnabled,
            duckingEnabled: store.duckingEnabled,
            channels: ChannelConfigStore.shared.channels(for: knownBundleIDs)
        )
        guard let data = MixPillCoder.encode(configuration) else { return }
        control.applyConfiguration(data) { _ in }
    }

    /// Sends one app's full channel state, then (lazily) makes sure the
    /// core knows every discovered app's config as well.
    public func pushChannel(_ config: ChannelConfig) {
        guard let control, let data = MixPillCoder.encode(config) else { return }
        control.applyChannel(data)
    }

    public func pushChannels(_ configs: [ChannelConfig]) {
        for config in configs {
            pushChannel(config)
        }
    }

    public func removeChannel(_ bundleID: String) {
        control?.removeChannel(bundleID)
    }

    /// Tells the core whether the meters are on screen, so it can spend
    /// frames only while they are being looked at.
    public func setMeterDisplayActive(_ active: Bool) {
        control?.setMeterDisplayActive(active)
    }

    public func setMasterVolume(_ volume: Float) {
        control?.setMasterVolume(volume)
    }

    public func setLowLatencyEnabled(_ enabled: Bool) {
        control?.setLowLatencyEnabled(enabled)
    }

    public func setDuckingEnabled(_ enabled: Bool) {
        control?.setDuckingEnabled(enabled)
    }


    public func setDefaultOutputDeviceUID(_ uid: String, completion: @escaping @MainActor (Bool) -> Void) {
        guard let control else {
            completion(false)
            return
        }
        control.setDefaultOutputDeviceUID(uid) { success in
            Task { @MainActor in
                completion(success)
            }
        }
    }

    public func performManualRecovery() {
        control?.performManualRecovery()
    }

    // MARK: - Queries (core → UI, on demand)

    public func requestDiagnostics(completion: @escaping @MainActor (DiagnosticsDTO?) -> Void) {
        guard let control else {
            completion(nil)
            return
        }
        control.requestDiagnostics { data in
            let snapshot = MixPillCoder.decode(DiagnosticsDTO.self, from: data)
            Task { @MainActor in
                completion(snapshot)
            }
        }
    }

}

// MARK: - Core events (MixPillCoreEventsProtocol)

extension CoreBridge: MixPillCoreEventsProtocol {
    nonisolated public func coreDidBecomeReady() {
        Task { @MainActor in
            self.isConnected = true
            self.pushConfiguration()
        }
    }

    nonisolated public func appsChanged(_ data: Data) {
        guard let apps = MixPillCoder.decode([CoreAppInfo].self, from: data) else { return }
        Task { @MainActor in
            self.onAppsChanged?(apps)
        }
    }

    nonisolated public func levelsChanged(_ data: Data) {
        guard let payload = MixPillCoder.decode(LevelsPayload.self, from: data) else { return }
        Task { @MainActor in
            self.onLevels?(payload)
        }
    }

    nonisolated public func devicesChanged(_ data: Data) {
        guard let payload = MixPillCoder.decode(DevicesPayload.self, from: data) else { return }
        Task { @MainActor in
            self.routingColumns = payload.columns
            self.devices = payload.devices
            self.defaultDeviceUID = payload.defaultDeviceUID
        }
    }


    nonisolated public func recoveryOccurred(reason: String, date: Date) {
        Task { @MainActor in
            self.onRecovery?(reason, date)
        }
    }

    nonisolated public func captureAvailabilityChanged(available: Bool, reason: String) {
        Task { @MainActor in
            self.captureProblem = available ? nil : reason
        }
    }
}
