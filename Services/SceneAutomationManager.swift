import Foundation
import Observation

/// Scene automation: rule-based preset switching.
///
/// Rules fire when their trigger application launches (detected by diffing
/// consecutive discovery snapshots). Smart Ducking no longer lives here —
/// it runs inside the MixPillCore service, decision at 10 Hz and ramp on
/// the render thread, so ducking survives even if the UI quits.
@MainActor
@Observable
public final class SceneAutomationManager {
    public static let shared = SceneAutomationManager()

    public var rules: [AutomationRuleModel] = [] {
        didSet { persistRules() }
    }

    /// Wired by `AppDelegate`; both references stay weak because the
    /// manager outlives any single automation evaluation.
    public weak var presetManager: PresetManager?
    public weak var discoveryService: AppDiscoveryService?

    private var knownAppBundleIDs: Set<String> = []
    private var hasBaseline = false

    private init() {
        loadRules()
    }

    // MARK: - Rule management

    public func addRule(triggerAppBundleID: String, triggerAppName: String) {
        let rule = AutomationRuleModel(
            name: "When \(triggerAppName) opens",
            triggerAppBundleID: triggerAppBundleID,
            triggerAppName: triggerAppName,
            presetID: presetManager?.presets.first?.id,
            isEnabled: true
        )
        rules.append(rule)
    }

    public func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    // MARK: - Rule evaluation

    /// Called whenever the core reports a changed application list.
    public func evaluateLaunchRules(apps: [AudioAppModel]) {
        let currentIDs = Set(apps.map(\.id))
        let previousIDs = knownAppBundleIDs
        knownAppBundleIDs = currentIDs

        // The first snapshot only establishes the baseline so apps that
        // are already running at launch do not fire their rules.
        guard hasBaseline else {
            hasBaseline = true
            return
        }

        let newlyLaunched = currentIDs.subtracting(previousIDs)
        guard !newlyLaunched.isEmpty else { return }

        for rule in rules where rule.isEnabled && newlyLaunched.contains(rule.triggerAppBundleID) {
            guard let presetID = rule.presetID, let discoveryService else { continue }
            print("SceneAutomation: rule '\(rule.name)' fired")
            presetManager?.applyPreset(id: presetID, to: discoveryService)
        }
    }

    // MARK: - Persistence

    private func persistRules() {
        do {
            let data = try JSONEncoder().encode(rules)
            UserDefaults.standard.set(data, forKey: Constants.StorageKeys.automationRules)
        } catch {
            print("SceneAutomationManager: failed to save rules: \(error)")
        }
    }

    private func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: Constants.StorageKeys.automationRules) else { return }
        do {
            rules = try JSONDecoder().decode([AutomationRuleModel].self, from: data)
        } catch {
            print("SceneAutomationManager: failed to load rules: \(error)")
        }
    }
}
