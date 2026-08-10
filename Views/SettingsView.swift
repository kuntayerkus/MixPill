import SwiftUI
import AppKit

public struct SettingsView: View {
    public init() {}

    public var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape.fill")
                }

            PresetsSettingsView()
                .tabItem {
                    Label("Presets", systemImage: "list.star")
                }

            AutomationRulesView()
                .tabItem {
                    Label("Automation", systemImage: "bolt.horizontal.fill")
                }

            MatrixRouterView()
                .tabItem {
                    Label("Routing", systemImage: "arrow.triangle.branch")
                }

            DiagnosticsView()
                .tabItem {
                    Label("Diagnostics", systemImage: "stethoscope")
                }
        }
        .padding(20)
        .frame(minWidth: 650, minHeight: 450)
    }
}

private struct GeneralSettingsView: View {
    @Environment(PermissionManager.self) private var permissionManager

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { LaunchAtLoginService.isEnabled },
                    set: { LaunchAtLoginService.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                            .font(.system(size: 13, weight: .medium))
                        Text("Launch MixPill automatically when you log into your Mac.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("Starts MixPill automatically at login")
            } header: {
                SettingsSectionHeader("Startup")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { GlobalHotkeyManager.shared.isEnabled },
                    set: { GlobalHotkeyManager.shared.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Global Hotkeys & Quick Gestures")
                            .font(.system(size: 13, weight: .medium))
                        Text("⌥ + Scroll adjusts the frontmost app's volume · ⌘⌥M mutes it — anywhere on your Mac, without opening the popover.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("Lets you control volumes from any app using keyboard and scroll shortcuts")

                if GlobalHotkeyManager.shared.isEnabled && !GlobalHotkeyManager.shared.isAccessibilityTrusted {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility access needed")
                                .font(.system(size: 13, weight: .medium))
                            Text("Turn MixPill on under Privacy & Security › Accessibility. This updates itself.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button("Open System Settings") {
                            permissionManager.openAccessibilitySettings()
                            GlobalHotkeyManager.shared.startWatchingForTrust()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } header: {
                SettingsSectionHeader("Global Hotkeys")
            } footer: {
                Text("MixPill never asks for Accessibility access unless you turn hotkeys on.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { ChannelConfigStore.shared.lowLatencyEnabled },
                    set: { ChannelConfigStore.shared.setLowLatencyEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ultra-Low Latency Mode")
                            .font(.system(size: 13, weight: .medium))
                        Text("Shrinks both the capture and playback blocks. Lower delay, less headroom against dropouts.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityHint("Reduces audio delay for live monitoring and lip-synced video at slightly higher CPU usage")
            } header: {
                SettingsSectionHeader("Audio Performance")
            } footer: {
                Text("Standard buffers capture generously so audio never breaks up, at about 20 ms of delay — right for music, video and games. Ultra-Low cuts that for live monitoring, but leaves the system less room to keep up and can click on busy machines or wide audio interfaces.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { UpdateService.shared.automaticallyChecksForUpdates },
                    set: { UpdateService.shared.automaticallyChecksForUpdates = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Check for Updates Automatically")
                            .font(.system(size: 13, weight: .medium))
                        Text("Looks once a day and only interrupts you when there is something to install.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack {
                    Text(UpdateService.shared.versionDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Check Now") {
                        UpdateService.shared.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .disabled(!UpdateService.shared.canCheckForUpdates)
                }
            } header: {
                SettingsSectionHeader("Updates")
            } footer: {
                Text("MixPill is distributed directly rather than through the App Store, so it updates itself. Only a request for the update feed leaves your Mac — no usage data, ever.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // The user may have just granted Accessibility permission in
            // System Settings; pick it up without requiring a relaunch.
            GlobalHotkeyManager.shared.refreshTrust()
        }
    }
}

private struct PresetsSettingsView: View {
    @Environment(PresetManager.self) private var presetManager
    @Environment(AppDiscoveryService.self) private var discoveryService

    var body: some View {
        Form {
            Section {
                if presetManager.presets.isEmpty {
                    HStack(spacing: Constants.UI.interElementSpacing) {
                        Image(systemName: "tray")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tertiary)
                        Text("No Presets Saved")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let activeID = presetManager.activePresetID()
                    ForEach(presetManager.presets) { preset in
                        PresetRow(
                            preset: preset,
                            isActive: preset.id == activeID,
                            onRename: { presetManager.renamePreset(id: preset.id, to: $0) },
                            onApply: { presetManager.applyPreset(id: preset.id, to: discoveryService) },
                            onOverwrite: {
                                presetManager.overwritePreset(id: preset.id, with: discoveryService.availableApps)
                            },
                            onDelete: { presetManager.deletePreset(id: preset.id) }
                        )
                    }
                }
            } header: {
                SettingsSectionHeader("Saved Presets")
            } footer: {
                Text("A preset captures every app's volume, mute, equalizer, noise gate and output device. Save one from the menu bar popover, then apply it by hand, from an automation rule, or from a Focus filter.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// One saved preset: rename in place, apply, re-capture, delete.
private struct PresetRow: View {
    let preset: PresetModel
    let isActive: Bool
    let onRename: (String) -> Void
    let onApply: () -> Void
    let onOverwrite: () -> Void
    let onDelete: () -> Void

    @State private var draftName = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: Constants.UI.interElementSpacing) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "slider.vertical.3")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .modifier(ConditionalHelp(text: isActive ? "This preset matches the current mix" : nil))

            VStack(alignment: .leading, spacing: 1) {
                // Editable in place — presets were auto-named "Preset 3"
                // with no way to change it, which makes an automation rule
                // pointing at one unreadable.
                TextField("Preset name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .focused($editing)
                    .onSubmit { commitName() }
                    .onChange(of: editing) { _, isEditing in
                        if !isEditing { commitName() }
                    }

                Text(preset.channels.count == 1
                     ? "1 app"
                     : "\(preset.channels.count) apps")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Apply", action: onApply)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isActive)

            Button {
                onOverwrite()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Replace this preset with the mixer's current state")
            .accessibilityLabel("Update preset \(preset.name) from the current mix")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.borderless)
            .help("Delete preset")
            .accessibilityLabel("Delete preset \(preset.name)")
        }
        .onAppear { draftName = preset.name }
        .onChange(of: preset.name) { _, name in
            if !editing { draftName = name }
        }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            draftName = preset.name
            return
        }
        guard trimmed != preset.name else { return }
        onRename(trimmed)
    }
}
