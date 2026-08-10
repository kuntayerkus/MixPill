import Foundation
import Observation
import AppKit

/// UI-side application model manager.
///
/// After the XPC decomposition, enumeration and capture live in the
/// MixPillCore service; this class turns the core's `CoreAppInfo` events
/// into the rich `AudioAppModel` list the SwiftUI layer renders (adding
/// icons, persisted volume/mute state, and live levels), and forwards the
/// snapshots to automation rules.
@MainActor
@Observable
public final class AppDiscoveryService {
    public var availableApps: [AudioAppModel] = []

    private let bridge: CoreBridge

    public init(bridge: CoreBridge) {
        self.bridge = bridge

        bridge.onAppsChanged = { [weak self] apps in
            self?.handleCoreApps(apps)
        }
        bridge.onLevels = { [weak self] payload in
            self?.handleLevels(payload)
        }
    }

    /// Connects the bridge so the UI starts receiving discovery and level
    /// events. Capture itself is the core's business and does not wait on
    /// the interface. There is nothing to "stop" here: quitting the UI
    /// must never interrupt audio, so the core keeps running.
    public func startDiscovery() {
        bridge.connect()
    }

    /// Kept for call-site symmetry; intentionally a no-op (see above).
    public func stopDiscovery() {}

    // MARK: - Core events

    private func handleCoreApps(_ coreApps: [CoreAppInfo]) {
        let runningApplications = NSWorkspace.shared.runningApplications
        var newModels: [AudioAppModel] = []
        var seen = Set<String>()

        for info in coreApps {
            let runningApp = runningApplications.first(where: { $0.bundleIdentifier == info.bundleID })
            if let runningApp, runningApp.activationPolicy == .prohibited {
                continue
            }

            let existing = availableApps.first(where: { $0.id == info.bundleID })
            let store = ChannelConfigStore.shared

            let model = AudioAppModel(
                id: info.bundleID,
                name: runningApp?.localizedName ?? info.name,
                icon: runningApp?.icon,
                volume: existing?.volume ?? store.volume(for: info.bundleID),
                isMuted: existing?.isMuted ?? store.isMuted(for: info.bundleID),
                audioLevel: existing?.audioLevel ?? 0.0,
                peakLevel: existing?.peakLevel ?? 0.0,
                isPlaying: info.isPlaying,
                isCapturingInput: info.isCapturingInput,
                isCaptured: info.isCaptured
            )

            if seen.insert(model.id).inserted {
                newModels.append(model)
            }
        }

        let previousIDs = Set(availableApps.map(\.id))
        availableApps = newModels

        // Make sure the core holds every app's desired channel state, and
        // remember the set so a reconnect can resend it in one snapshot.
        let bundleIDs = newModels.map(\.id)
        bridge.knownBundleIDs = bundleIDs
        bridge.pushChannels(ChannelConfigStore.shared.channels(for: bundleIDs))

        // Retire the strips for apps that have gone.
        //
        // `removeChannel` existed on both sides of the XPC contract and was
        // never called, so the core accumulated a channel strip for every
        // application that had played audio since it started — each one a
        // ring buffer and a DSP object still being read, filtered and summed
        // in the render callback long after the app had quit. The cost grew
        // with the length of the session, not with what was playing.
        for bundleID in previousIDs.subtracting(bundleIDs) {
            bridge.removeChannel(bundleID)
        }

        SceneAutomationManager.shared.evaluateLaunchRules(apps: availableApps)
    }

    private func handleLevels(_ payload: LevelsPayload) {
        guard !payload.samples.isEmpty else { return }

        let levelsByID = Dictionary(uniqueKeysWithValues: payload.samples.map { ($0.bundleID, $0) })
        for index in availableApps.indices {
            guard let sample = levelsByID[availableApps[index].id] else { continue }
            availableApps[index].audioLevel = max(0.0, min(1.0, sample.rms))
            availableApps[index].peakLevel = max(0.0, min(1.0, sample.peak))
        }
    }

    /// Reflects persisted store state back into the visible model. Used
    /// after hotkey/gesture changes that bypass the row bindings.
    public func refreshModelFromStore(for bundleID: String) {
        guard let index = availableApps.firstIndex(where: { $0.id == bundleID }) else { return }
        let store = ChannelConfigStore.shared
        availableApps[index].volume = store.volume(for: bundleID)
        availableApps[index].isMuted = store.isMuted(for: bundleID)
    }

    public func refreshModelsFromStore(for bundleIDs: [String]) {
        for bundleID in bundleIDs {
            refreshModelFromStore(for: bundleID)
        }
    }
}
