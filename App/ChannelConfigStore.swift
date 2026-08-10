import Foundation
import AppKit

/// The UI-side source of truth for every persisted audio preference.
///
/// In the decomposed architecture the MixPillCore XPC service is
/// stateless: it executes whatever desired state the UI sends and keeps
/// only runtime structures. This store owns the persistence (same
/// UserDefaults keys the pre-decomposition app used, so settings migrate
/// seamlessly) and pushes each change to the core through the bridge.
@MainActor
public final class ChannelConfigStore {
    public static let shared = ChannelConfigStore()

    /// Injected by `AppDelegate` once the bridge exists. Weak: the store
    /// is a process-wide singleton, the bridge is owned by the app object.
    public weak var bridge: CoreBridge?

    public static let flatEQGains: [Float] = [0, 0, 0, 0, 0]

    private init() {}

    // MARK: - DAW detection

    /// Detected DAWs default to DAW Direct, which leaves them untapped.
    /// The list is shared with the engine — see `DAWDetection`.
    public static func isDAW(bundleID: String) -> Bool {
        DAWDetection.isDAW(bundleID: bundleID)
    }

    // MARK: - Channel config assembly

    /// Assembles the full desired state for one app from persisted values.
    public func channelConfig(for bundleID: String) -> ChannelConfig {
        ChannelConfig(
            bundleID: bundleID,
            volume: persistedVolume(for: bundleID),
            isMuted: persistedMute(for: bundleID),
            eqGains: persistedEQGains(for: bundleID) ?? Self.flatEQGains,
            processingBypassed: persistedDawDirect(for: bundleID) ?? Self.isDAW(bundleID: bundleID),
            noiseGateThreshold: persistedNoiseGate(for: bundleID),
            compressorEnabled: persistedNightMode(for: bundleID),
            routePairID: routingPairID(for: bundleID)
        )
    }

    public func channels(for bundleIDs: [String]) -> [ChannelConfig] {
        bundleIDs.map { channelConfig(for: $0) }
    }

    // MARK: - Volume & mute

    public func setVolume(_ volume: Float, isMuted: Bool, for bundleID: String) {
        let clamped = max(0.0, min(1.0, volume))
        let previousVolume = persistedVolume(for: bundleID)
        let previousMute = persistedMute(for: bundleID)
        guard clamped != previousVolume || isMuted != previousMute else { return }

        applyVolume(clamped, isMuted: isMuted, for: bundleID)

        MixerUndoManager.shared.record(
            bundleID: bundleID,
            control: isMuted != previousMute ? "mute" : "volume",
            label: isMuted != previousMute
                ? (isMuted ? "Mute \(displayName(for: bundleID))" : "Unmute \(displayName(for: bundleID))")
                : "\(displayName(for: bundleID)) Volume",
            undo: { [weak self] in self?.applyVolume(previousVolume, isMuted: previousMute, for: bundleID) },
            redo: { [weak self] in self?.applyVolume(clamped, isMuted: isMuted, for: bundleID) }
        )
    }

    /// The change itself, with no undo bookkeeping — used both by the
    /// public setter and by undo/redo replaying it.
    private func applyVolume(_ volume: Float, isMuted: Bool, for bundleID: String) {
        persistVolume(volume, for: bundleID)
        persistMute(isMuted, for: bundleID)
        pushChannel(bundleID)
    }

    /// A readable name for undo menu titles.
    private func displayName(for bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first?.localizedName
            ?? bundleID.components(separatedBy: ".").last
            ?? bundleID
    }

    @discardableResult
    public func adjustVolume(by amount: Float, for bundleID: String) -> Float {
        let updated = max(0.0, min(1.0, persistedVolume(for: bundleID) + amount))
        persistVolume(updated, for: bundleID)
        pushChannel(bundleID)
        return updated
    }

    @discardableResult
    public func toggleMute(for bundleID: String) -> Bool {
        let updated = !persistedMute(for: bundleID)
        persistMute(updated, for: bundleID)
        pushChannel(bundleID)
        return updated
    }

    public func volume(for bundleID: String) -> Float { persistedVolume(for: bundleID) }
    public func isMuted(for bundleID: String) -> Bool { persistedMute(for: bundleID) }

    // MARK: - EQ

    public func setEQGains(_ gains: [Float], for bundleID: String) {
        let previous = persistedEQGains(for: bundleID) ?? Self.flatEQGains
        guard gains != previous else { return }

        applyEQGains(gains, for: bundleID)

        MixerUndoManager.shared.record(
            bundleID: bundleID,
            control: "eq",
            label: "\(displayName(for: bundleID)) Equalizer",
            undo: { [weak self] in self?.applyEQGains(previous, for: bundleID) },
            redo: { [weak self] in self?.applyEQGains(gains, for: bundleID) }
        )
    }

    private func applyEQGains(_ gains: [Float], for bundleID: String) {
        persistEQGains(gains, for: bundleID)
        pushChannel(bundleID)
    }

    public func eqGains(for bundleID: String) -> [Float] {
        persistedEQGains(for: bundleID) ?? Self.flatEQGains
    }

    // MARK: - Noise gate

    public func setNoiseGate(threshold: Float, for bundleID: String) {
        persistNoiseGate(max(0, min(1, threshold)), for: bundleID)
        pushChannel(bundleID)
    }

    public func noiseGate(for bundleID: String) -> Float {
        persistedNoiseGate(for: bundleID)
    }

    // MARK: - Night Mode (compression)

    public func setNightMode(enabled: Bool, for bundleID: String) {
        persistNightMode(enabled, for: bundleID)
        pushChannel(bundleID)
    }

    public func isNightMode(for bundleID: String) -> Bool {
        persistedNightMode(for: bundleID)
    }

    // MARK: - DAW Direct bypass

    public func setDawDirectMode(enabled: Bool, for bundleID: String) {
        persistDawDirect(enabled, for: bundleID)
        pushChannel(bundleID)
    }

    public func isDawDirectMode(for bundleID: String) -> Bool {
        persistedDawDirect(for: bundleID) ?? Self.isDAW(bundleID: bundleID)
    }

    // MARK: - Routing

    /// The desired routing target id: "system-default" or a pair id.
    /// Echo-free fallback resolution happens in the core.
    public func routingPairID(for bundleID: String) -> String {
        let routes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.routing) as? [String: String] ?? [:]
        return routes[bundleID] ?? "system-default"
    }

    public func setRouting(pairID: String, for bundleID: String) {
        var routes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.routing) as? [String: String] ?? [:]
        if pairID == "system-default" {
            routes.removeValue(forKey: bundleID)
        } else {
            routes[bundleID] = pairID
        }
        UserDefaults.standard.set(routes, forKey: Constants.StorageKeys.routing)
        pushChannel(bundleID)
    }

    public func setRouting(pairID: String, forAllApps bundleIDs: [String]) {
        for bundleID in bundleIDs {
            setRouting(pairID: pairID, for: bundleID)
        }
    }

    // MARK: - Global settings

    public var masterVolume: Float {
        UserDefaults.standard.object(forKey: Constants.StorageKeys.masterVolume) as? Float ?? 1.0
    }

    public func setMasterVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        UserDefaults.standard.set(clamped, forKey: Constants.StorageKeys.masterVolume)
        bridge?.setMasterVolume(clamped)
    }

    public var lowLatencyEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.lowLatencyMode)
    }

    public func setLowLatencyEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constants.StorageKeys.lowLatencyMode)
        bridge?.setLowLatencyEnabled(enabled)
    }

    public var duckingEnabled: Bool {
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.duckingEnabled)
    }

    public func setDuckingEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Constants.StorageKeys.duckingEnabled)
        bridge?.setDuckingEnabled(enabled)
    }


    // MARK: - Push helper

    private func pushChannel(_ bundleID: String) {
        bridge?.pushChannel(channelConfig(for: bundleID))
    }

    // MARK: - Persistence primitives

    private func persistedVolume(for bundleID: String) -> Float {
        let volumes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.appVolumes) as? [String: Float] ?? [:]
        return volumes[bundleID] ?? 1.0
    }

    private func persistedMute(for bundleID: String) -> Bool {
        let mutes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.appMutes) as? [String: Bool] ?? [:]
        return mutes[bundleID] ?? false
    }

    private func persistedEQGains(for bundleID: String) -> [Float]? {
        let gains = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.eqGains) as? [String: [Float]] ?? [:]
        return gains[bundleID]
    }

    private func persistedNoiseGate(for bundleID: String) -> Float {
        let gates = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.noiseGates) as? [String: Float] ?? [:]
        return gates[bundleID] ?? 0.0
    }

    private func persistedNightMode(for bundleID: String) -> Bool {
        let modes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.nightModes) as? [String: Bool] ?? [:]
        return modes[bundleID] ?? false
    }

    private func persistedDawDirect(for bundleID: String) -> Bool? {
        let modes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.dawDirectModes) as? [String: Bool] ?? [:]
        return modes[bundleID]
    }

    private func persistVolume(_ volume: Float, for bundleID: String) {
        var volumes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.appVolumes) as? [String: Float] ?? [:]
        volumes[bundleID] = volume
        UserDefaults.standard.set(volumes, forKey: Constants.StorageKeys.appVolumes)
    }

    private func persistMute(_ isMuted: Bool, for bundleID: String) {
        var mutes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.appMutes) as? [String: Bool] ?? [:]
        mutes[bundleID] = isMuted
        UserDefaults.standard.set(mutes, forKey: Constants.StorageKeys.appMutes)
    }

    private func persistEQGains(_ gains: [Float], for bundleID: String) {
        var all = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.eqGains) as? [String: [Float]] ?? [:]
        all[bundleID] = gains
        UserDefaults.standard.set(all, forKey: Constants.StorageKeys.eqGains)
    }

    private func persistNoiseGate(_ threshold: Float, for bundleID: String) {
        var gates = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.noiseGates) as? [String: Float] ?? [:]
        gates[bundleID] = threshold
        UserDefaults.standard.set(gates, forKey: Constants.StorageKeys.noiseGates)
    }

    private func persistNightMode(_ enabled: Bool, for bundleID: String) {
        var modes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.nightModes) as? [String: Bool] ?? [:]
        modes[bundleID] = enabled
        UserDefaults.standard.set(modes, forKey: Constants.StorageKeys.nightModes)
    }

    private func persistDawDirect(_ enabled: Bool, for bundleID: String) {
        var modes = UserDefaults.standard.dictionary(forKey: Constants.StorageKeys.dawDirectModes) as? [String: Bool] ?? [:]
        modes[bundleID] = enabled
        UserDefaults.standard.set(modes, forKey: Constants.StorageKeys.dawDirectModes)
    }
}
