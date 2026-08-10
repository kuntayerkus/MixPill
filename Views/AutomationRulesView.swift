import SwiftUI

public struct AutomationRulesView: View {
    @Environment(PresetManager.self) private var presetManager
    @Environment(AppDiscoveryService.self) private var discoveryService
    @Bindable var automationManager = SceneAutomationManager.shared

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { ChannelConfigStore.shared.duckingEnabled },
                    set: { ChannelConfigStore.shared.setDuckingEnabled($0) }
                ).animation(Constants.Motion.spring)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smart Ducking")
                            .font(.system(size: 13, weight: .medium))
                        // Describes what the engine actually keys on. There
                        // is no app list any more: DuckingController watches
                        // which process is holding the microphone, so
                        // FaceTime, a meeting in a browser tab and whatever
                        // ships next all work without being named anywhere.
                        Text("While an app is holding your microphone and producing sound, everything else dips smoothly to 20% and comes back when the talking stops. There's no list of apps to keep up to date — FaceTime, meetings in a browser tab and anything released tomorrow all count. Ducking runs inside the MixPillCore service, so it keeps working with the popover closed.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("Automatically lowers other apps while somebody is speaking on a call")
            } header: {
                SettingsSectionHeader("Ducking Rules")
            }

            Section {
                if automationManager.rules.isEmpty {
                    HStack(spacing: Constants.UI.interElementSpacing) {
                        Image(systemName: "wand.and.stars")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tertiary)
                        Text("No Automation Rules")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Spacer()
                        addRuleMenu
                    }
                } else {
                    ForEach($automationManager.rules) { $rule in
                        AutomationRuleRow(rule: $rule) {
                            automationManager.deleteRule(id: rule.id)
                        }
                    }

                    HStack {
                        Spacer()
                        addRuleMenu
                    }
                }
            } header: {
                SettingsSectionHeader("Preset Switching")
            } footer: {
                Text("Rules apply a preset automatically when an application launches. E.g., “When Spotify opens, set Profile to Music Mode.”")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .animation(Constants.Motion.spring, value: automationManager.rules)
    }

    // MARK: - Add Rule

    /// Apps that do not have a rule yet, in the same order as the app list.
    private var addableApps: [AudioAppModel] {
        let covered = Set(automationManager.rules.map(\.triggerAppBundleID))
        return discoveryService.availableApps.filter { !covered.contains($0.id) }
    }

    private var addRuleMenu: some View {
        Menu {
            if addableApps.isEmpty {
                Text("No Eligible Apps")
            } else {
                ForEach(addableApps) { app in
                    Button {
                        automationManager.addRule(
                            triggerAppBundleID: app.id,
                            triggerAppName: app.name
                        )
                    } label: {
                        if let icon = app.icon {
                            Label {
                                Text(app.name)
                            } icon: {
                                Image(nsImage: icon)
                            }
                        } else {
                            Label(app.name, systemImage: "app")
                        }
                    }
                }
            }
        } label: {
            Label("Add Rule", systemImage: "plus")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .disabled(presetManager.presets.isEmpty || addableApps.isEmpty)
        .help(presetManager.presets.isEmpty
            ? "Save a preset first to create automation rules"
            : "Create a rule that applies a preset when an app opens")
        .accessibilityLabel("Add automation rule")
    }
}

private struct AutomationRuleRow: View {
    @Environment(PresetManager.self) private var presetManager
    @Binding var rule: AutomationRuleModel
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: Constants.UI.interElementSpacing) {
            // `Toggle("")` would register a blank key in the String
            // Catalog; the label is hidden anyway and the switch carries
            // its own accessibility label below.
            Toggle(isOn: $rule.isEnabled) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(rule.isEnabled ? "Disable \(rule.name)" : "Enable \(rule.name)")

            Image(systemName: "app.badge")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(rule.isEnabled ? Color.accentColor : Color.secondary)
                .animation(Constants.Motion.spring, value: rule.isEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(rule.isEnabled ? Color.primary : Color.secondary)
                Text("Applies the selected preset when \(rule.triggerAppName) launches.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Picker("Preset", selection: $rule.presetID) {
                Text("None").tag(UUID?.none)
                ForEach(presetManager.presets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 160)
            .accessibilityLabel("Preset for \(rule.name)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Delete rule")
            .accessibilityLabel("Delete rule \(rule.name)")
        }
        .animation(Constants.Motion.spring, value: rule.isEnabled)
    }
}
