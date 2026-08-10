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
                    Label("Routing", systemImage: "arrow.triangle.swap")
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
                    ForEach(presetManager.presets) { preset in
                        HStack(spacing: Constants.UI.interElementSpacing) {
                            Label {
                                Text(preset.name)
                                    .font(.system(size: 13, weight: .medium))
                            } icon: {
                                Image(systemName: "slider.vertical.3")
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                presetManager.deletePreset(id: preset.id)
                            } label: {
                                Image(systemName: "trash")
                                    .symbolRenderingMode(.hierarchical)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete preset")
                            .accessibilityLabel("Delete preset \(preset.name)")
                        }
                    }
                }
            } header: {
                SettingsSectionHeader("Saved Presets")
            } footer: {
                Text("Save presets from the menu bar popover to capture every app's volume and mute state.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
