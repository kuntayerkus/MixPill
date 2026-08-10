import Foundation
import AppKit
import Observation

/// The UI-side source of truth for every persisted audio preference.
///
/// In the decomposed architecture the MixPillCore XPC service is
/// stateless: it executes whatever desired state the UI sends and keeps
/// only runtime structures. This store owns the persistence (same
/// UserDefaults keys the pre-decomposition app used, so settings migrate
/// seamlessly) and pushes each change to the core through the bridge.
@MainActor
@Observable
public final class ChannelConfigStore {
    public static let shared = ChannelConfigStore()

    /// Routing held in memory as well as in `UserDefaults`.
    ///
    /// Reading a preference straight from `UserDefaults` inside a view's
    /// body is invisible to SwiftUI: the value changes, nothing re-renders,
    /// and a checkmark stays on whatever was selected when the view was
    /// built. Observation only tracks stored properties, so the routing
    /// table has to be one.
    private var routes: [String: String] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.routing) as? [String: String] ?? [:]

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
            isMuted: isEffectivelyMuted(bundleID),
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

    // MARK: - Solo

    /// The app currently soloed, if any. Deliberately not persisted: solo
    /// is a thing you do for a minute, not a setting, and finding every
    /// other app muted after a restart would be a bug rather than a
    /// restored preference.
    public private(set) var soloedBundleID: String?

    /// Whether this channel is silent right now, counting solo. Solo
    /// overlays the persisted mute rather than overwriting it, so releasing
    /// it puts every app back exactly where it was.
    public func isEffectivelyMuted(_ bundleID: String) -> Bool {
        if let soloedBundleID, soloedBundleID != bundleID { return true }
        return persistedMute(for: bundleID)
    }

    public func toggleSolo(for bundleID: String) {
        soloedBundleID = soloedBundleID == bundleID ? nil : bundleID
        pushAllChannels()
    }

    public func clearSolo() {
        guard soloedBundleID != nil else { return }
        soloedBundleID = nil
        pushAllChannels()
    }

    // MARK: - Preset snapshots

    /// The full saved state of one app, for putting into a preset.
    public func presetChannel(for bundleID: String) -> PresetChannel {
        PresetChannel(
            volume: persistedVolume(for: bundleID),
            isMuted: persistedMute(for: bundleID),
            eqGains: eqGains(for: bundleID),
            noiseGateThreshold: persistedNoiseGate(for: bundleID),
            compressorEnabled: persistedNightMode(for: bundleID),
            routePairID: routingPairID(for: bundleID),
            dawDirect: isDawDirectMode(for: bundleID)
        )
    }

    public func presetSnapshot(of bundleIDs: [String]) -> [String: PresetChannel] {
        Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, presetChannel(for: $0)) })
    }

    /// Applies a preset's channels in one go, with no per-app undo entries
    /// — the caller records the whole thing as a single step, so ⌘Z undoes
    /// "apply this preset" rather than unwinding it one application at a
    /// time.
    public func applyPresetChannels(_ channels: [String: PresetChannel]) {
        for (bundleID, channel) in channels {
            persistVolume(max(0, min(AudioScale.maximumChannelGain, channel.volume)), for: bundleID)
            persistMute(channel.isMuted, for: bundleID)
            if let gains = channel.eqGains { persistEQGains(gains, for: bundleID) }
            if let gate = channel.noiseGateThreshold { persistNoiseGate(gate, for: bundleID) }
            if let compressor = channel.compressorEnabled { persistNightMode(compressor, for: bundleID) }
            if let dawDirect = channel.dawDirect { persistDawDirect(dawDirect, for: bundleID) }
            if let pairID = channel.routePairID {
                if pairID == "system-default" {
                    routes.removeValue(forKey: bundleID)
                } else {
                    routes[bundleID] = pairID
                }
                scheduleFlush(Constants.StorageKeys.routing)
            }
        }
        bridge?.pushChannels(channels.keys.map { channelConfig(for: $0) })
    }

    /// True when every app the preset mentions already matches it.
    public func matchesCurrentState(_ channels: [String: PresetChannel]) -> Bool {
        channels.allSatisfy { bundleID, saved in
            let current = presetChannel(for: bundleID)
            if abs(current.volume - saved.volume) > 0.001 { return false }
            if current.isMuted != saved.isMuted { return false }
            if let gains = saved.eqGains, gains != current.eqGains { return false }
            if let gate = saved.noiseGateThreshold, abs(gate - (current.noiseGateThreshold ?? 0)) > 0.0001 { return false }
            if let compressor = saved.compressorEnabled, compressor != current.compressorEnabled { return false }
            if let pairID = saved.routePairID, pairID != current.routePairID { return false }
            if let dawDirect = saved.dawDirect, dawDirect != current.dawDirect { return false }
            return true
        }
    }

    private func pushAllChannels() {
        guard let bridge else { return }
        bridge.pushChannels(channels(for: bridge.knownBundleIDs))
    }

    // MARK: - Volume & mute

    public func setVolume(_ volume: Float, isMuted: Bool, for bundleID: String) {
        let clamped = max(0.0, min(AudioScale.maximumChannelGain, volume))
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

    /// Nudges a channel by a step of *fader travel*, not of raw gain.
    ///
    /// ⌥-scroll used to add 0.05 to the linear gain, which is a barely
    /// audible nudge near unity and a jump of tens of decibels near
    /// silence. Stepping the fader position instead makes every notch the
    /// same perceived change, wherever the fader happens to be.
    @discardableResult
    public func adjustVolume(by positionDelta: Float, for bundleID: String) -> Float {
        let current = persistedVolume(for: bundleID)
        let position = AudioScale.position(forGain: current) + positionDelta
        let updated = AudioScale.gain(forPosition: position)
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
        routes[bundleID] ?? "system-default"
    }

    public func setRouting(pairID: String, for bundleID: String) {
        let previous = routes[bundleID]
        guard previous != (pairID == "system-default" ? nil : pairID) else { return }

        applyRouting(pairID: pairID, for: bundleID)

        MixerUndoManager.shared.record(
            bundleID: bundleID,
            control: "routing",
            label: "\(displayName(for: bundleID)) Output",
            undo: { [weak self] in
                self?.applyRouting(pairID: previous ?? "system-default", for: bundleID)
            },
            redo: { [weak self] in self?.applyRouting(pairID: pairID, for: bundleID) }
        )
    }

    private func applyRouting(pairID: String, for bundleID: String) {
        if pairID == "system-default" {
            routes.removeValue(forKey: bundleID)
        } else {
            routes[bundleID] = pairID
        }
        scheduleFlush(Constants.StorageKeys.routing)
        pushChannel(bundleID)
    }

    /// Routes several apps without recording an undo entry each — the
    /// caller wraps the whole move in one transaction.
    public func setRoutingWithoutUndo(pairID: String, for bundleIDs: [String]) {
        for bundleID in bundleIDs {
            applyRouting(pairID: pairID, for: bundleID)
        }
    }

    // MARK: - Global settings

    public var masterVolume: Float {
        UserDefaults.standard.object(forKey: Constants.StorageKeys.masterVolume) as? Float ?? 1.0
    }

    /// What the engine should actually run at, counting master mute.
    public var effectiveMasterVolume: Float {
        isMasterMuted ? 0 : masterVolume
    }

    public func setMasterVolume(_ volume: Float) {
        let clamped = max(0.0, min(1.0, volume))
        UserDefaults.standard.set(clamped, forKey: Constants.StorageKeys.masterVolume)
        pushMasterVolume()
    }

    /// Master mute, kept separate from the fader so unmuting returns to the
    /// level you were at rather than to wherever the knob was dragged.
    public var isMasterMuted: Bool {
        UserDefaults.standard.bool(forKey: Constants.StorageKeys.masterMuted)
    }

    public func setMasterMuted(_ muted: Bool) {
        UserDefaults.standard.set(muted, forKey: Constants.StorageKeys.masterMuted)
        pushMasterVolume()
    }

    private func pushMasterVolume() {
        bridge?.setMasterVolume(isMasterMuted ? 0 : masterVolume)
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

    /// Per-app settings live in memory and are written back on a short
    /// delay.
    ///
    /// Every getter used to read a whole dictionary out of `UserDefaults`
    /// and every setter used to read it, copy it, change one key and write
    /// it back. Dragging a fader does that sixty times a second, and each
    /// write serializes the values of *every* app — so the cost of moving
    /// one slider grew with how many apps had ever been seen. The gain
    /// still reaches the engine immediately; only the trip to disk waits.
    private static let flushDelay: Duration = .milliseconds(250)

    private var volumes: [String: Float] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.appVolumes) as? [String: Float] ?? [:]
    private var mutes: [String: Bool] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.appMutes) as? [String: Bool] ?? [:]
    private var eqGainsByID: [String: [Float]] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.eqGains) as? [String: [Float]] ?? [:]
    private var noiseGates: [String: Float] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.noiseGates) as? [String: Float] ?? [:]
    private var nightModes: [String: Bool] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.nightModes) as? [String: Bool] ?? [:]
    private var dawDirectModes: [String: Bool] = UserDefaults.standard
        .dictionary(forKey: Constants.StorageKeys.dawDirectModes) as? [String: Bool] ?? [:]

    private var pendingFlush: Set<String> = []
    private var flushTask: Task<Void, Never>?

    private func scheduleFlush(_ key: String) {
        pendingFlush.insert(key)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.flushDelay)
            guard !Task.isCancelled else { return }
            self?.flushPending()
        }
    }

    /// Writes everything that changed. Called on the debounce and, so a
    /// quit mid-drag cannot lose the last move, at termination.
    public func flushPending() {
        flushTask?.cancel()
        flushTask = nil
        guard !pendingFlush.isEmpty else { return }

        let defaults = UserDefaults.standard
        for key in pendingFlush {
            switch key {
            case Constants.StorageKeys.appVolumes:    defaults.set(volumes, forKey: key)
            case Constants.StorageKeys.appMutes:      defaults.set(mutes, forKey: key)
            case Constants.StorageKeys.eqGains:       defaults.set(eqGainsByID, forKey: key)
            case Constants.StorageKeys.noiseGates:    defaults.set(noiseGates, forKey: key)
            case Constants.StorageKeys.nightModes:    defaults.set(nightModes, forKey: key)
            case Constants.StorageKeys.dawDirectModes: defaults.set(dawDirectModes, forKey: key)
            case Constants.StorageKeys.routing:       defaults.set(routes, forKey: key)
            default: break
            }
        }
        pendingFlush.removeAll()
    }

    private func persistedVolume(for bundleID: String) -> Float { volumes[bundleID] ?? 1.0 }
    private func persistedMute(for bundleID: String) -> Bool { mutes[bundleID] ?? false }
    private func persistedEQGains(for bundleID: String) -> [Float]? { eqGainsByID[bundleID] }
    private func persistedNoiseGate(for bundleID: String) -> Float { noiseGates[bundleID] ?? 0.0 }
    private func persistedNightMode(for bundleID: String) -> Bool { nightModes[bundleID] ?? false }
    private func persistedDawDirect(for bundleID: String) -> Bool? { dawDirectModes[bundleID] }

    private func persistVolume(_ volume: Float, for bundleID: String) {
        volumes[bundleID] = volume
        scheduleFlush(Constants.StorageKeys.appVolumes)
    }

    private func persistMute(_ isMuted: Bool, for bundleID: String) {
        mutes[bundleID] = isMuted
        scheduleFlush(Constants.StorageKeys.appMutes)
    }

    private func persistEQGains(_ gains: [Float], for bundleID: String) {
        eqGainsByID[bundleID] = gains
        scheduleFlush(Constants.StorageKeys.eqGains)
    }

    private func persistNoiseGate(_ threshold: Float, for bundleID: String) {
        noiseGates[bundleID] = threshold
        scheduleFlush(Constants.StorageKeys.noiseGates)
    }

    private func persistNightMode(_ enabled: Bool, for bundleID: String) {
        nightModes[bundleID] = enabled
        scheduleFlush(Constants.StorageKeys.nightModes)
    }

    private func persistDawDirect(_ enabled: Bool, for bundleID: String) {
        dawDirectModes[bundleID] = enabled
        scheduleFlush(Constants.StorageKeys.dawDirectModes)
    }
}
