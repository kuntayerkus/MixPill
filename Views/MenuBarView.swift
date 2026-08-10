import SwiftUI
import AppKit

public struct MenuBarView: View {
    @Environment(AppDiscoveryService.self) private var discoveryService
    @Environment(PresetManager.self) private var presetManager
    @Environment(CoreBridge.self) private var coreBridge

    @State private var searchText = ""
    @State private var masterVolume: Float = ChannelConfigStore.shared.masterVolume
    @FocusState private var searchFocused: Bool
    @State private var showIdleApps = false

    private var playingIDs: Set<String> {
        Set(discoveryService.availableApps.filter(\.isPlaying).map(\.id))
    }

    private var idleIDs: Set<String> {
        Set(discoveryService.availableApps.filter { !$0.isPlaying }.map(\.id))
    }

    private func matchesSearch(_ app: AudioAppModel) -> Bool {
        searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
    }

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider()
                .padding(.horizontal, Constants.UI.edgePadding)

            // The mixer is always shown. MixPill needs no permission to do
            // its job — process taps just work — so there is no gate here.
            // A problem banner appears only if the core actually fails to
            // capture, and it says what went wrong rather than guessing.
            if let problem = coreBridge.captureProblem {
                CaptureProblemBanner(message: problem)
            }

            appList

            Divider()
                .padding(.horizontal, Constants.UI.edgePadding)

            footer
        }
        .frame(width: Constants.UI.popoverWidth)
        // Structural guard, not decoration. The popover is a fixed 320 pt,
        // but a child that demands more — a menu sized to a 64-channel
        // interface's "Outputs 63-64" entries, say — will otherwise
        // overflow it and drag the whole layout sideways. Clipping keeps a
        // future mistake ugly instead of unusable.
        .clipped()
        .background(VisualEffectBackground())
        .animation(Constants.Motion.spring, value: coreBridge.captureProblem)
        .onAppear {
            // Meters only need to run fast while someone is watching them.
            coreBridge.setMeterDisplayActive(true)
            // The popover opens ready to type, so filtering a long list is
            // one keystroke rather than a click plus a keystroke.
            searchFocused = true
        }
        .onDisappear {
            coreBridge.setMeterDisplayActive(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Constants.UI.interElementSpacing) {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("MixPill")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Button(action: toggleFocusShield) {
                Image(systemName: FocusShieldManager.shared.isShieldActive ? "shield.fill" : "shield")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(FocusShieldManager.shared.isShieldActive ? Color.accentColor : Color.secondary)
                    .frame(width: Constants.UI.controlHeight, height: Constants.UI.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .symbolEffect(.bounce, value: FocusShieldManager.shared.isShieldActive)
            .contentTransition(.symbolEffect(.replace))
            .help(FocusShieldManager.shared.isShieldActive
                ? "Focus Shield is on: background apps cannot steal keyboard focus"
                : "Focus Shield is off: click to block background apps from stealing keyboard focus")
            .accessibilityLabel("Focus Shield")
            .accessibilityHint("Blocks background applications from stealing keyboard focus")

            Button(action: openSettings) {
                Image(systemName: "gearshape.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Constants.UI.controlHeight, height: Constants.UI.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)
            .help("MixPill Settings… (⌘,)")
            .accessibilityLabel("Settings")
            .accessibilityHint("Opens the MixPill settings window")

            Button(action: quitApp) {
                Image(systemName: "power")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: Constants.UI.controlHeight, height: Constants.UI.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
            .help("Quit MixPill (⌘Q)")
            .accessibilityLabel("Quit MixPill")
        }
        .padding(Constants.UI.edgePadding)
        // Escape closes the popover, standard macOS behavior. An empty
        // `Button("")` would work too, but it puts a blank key into the
        // String Catalog for translators to puzzle over.
        .background(
            ZStack {
                Button(action: closeWindow) { EmptyView() }
                    .keyboardShortcut(.cancelAction)

                // Undo lives on its standard keys. A mixer is a place people
                // experiment, and experimenting needs a way back.
                Button(action: MixerUndoManager.shared.performUndo) { EmptyView() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!MixerUndoManager.shared.canUndo)

                Button(action: MixerUndoManager.shared.performRedo) { EmptyView() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!MixerUndoManager.shared.canRedo)
            }
            .hidden()
            .accessibilityHidden(true)
        )
    }

    // MARK: - App list

    private var appList: some View {
        @Bindable var discovery = discoveryService

        return VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
            TextField("Search", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .accessibilityLabel("Search applications")
                .onChange(of: searchText) {
                    // Searching implies looking for something not in front
                    // of you, so open the quiet section rather than hiding
                    // the match inside a collapsed group.
                    if !searchText.isEmpty { showIdleApps = true }
                }

            ScrollView {
                VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
                    if discoveryService.availableApps.isEmpty {
                        // An empty state should say what to do next, not
                        // just report that nothing is here.
                        VStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .symbolRenderingMode(.hierarchical)
                                .font(.system(size: 26))
                                .foregroundStyle(.tertiary)
                            Text("Waiting for audio")
                                .font(.system(size: 13, weight: .medium))
                            Text("Play something in any app and it appears here with its own volume.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 22)
                        .padding(.horizontal, 8)
                    } else {
                        // Everything currently making sound, first and
                        // unadorned — that is what the popover was opened
                        // for.
                        if !playingIDs.isEmpty {
                            SettingsSectionHeader("Playing Now")
                        }
                        ForEach($discovery.availableApps) { $app in
                            if playingIDs.contains(app.id) && matchesSearch(app) {
                                AppVolumeRowView(app: $app) { volume, isMuted in
                                    ChannelConfigStore.shared.setVolume(volume, isMuted: isMuted, for: app.id)
                                }
                            }
                        }

                        // Apps that have not made a sound recently are still
                        // reachable — their settings persist and matter —
                        // but they are folded away so a day's worth of
                        // launched apps does not bury the two that are
                        // playing.
                        if !idleIDs.isEmpty {
                            DisclosureGroup(isExpanded: $showIdleApps) {
                                VStack(spacing: Constants.UI.interElementSpacing) {
                                    ForEach($discovery.availableApps) { $app in
                                        if idleIDs.contains(app.id) && matchesSearch(app) {
                                            AppVolumeRowView(app: $app) { volume, isMuted in
                                                ChannelConfigStore.shared.setVolume(volume, isMuted: isMuted, for: app.id)
                                            }
                                        }
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                // Spelled out rather than using inflection
                                // markup: `^[…](inflect: true)` only resolves
                                // through a localized string, and when it
                                // does not it is shown to the user verbatim.
                                SettingsSectionHeader(
                                    idleIDs.count == 1 ? "1 Quiet App" : "\(idleIDs.count) Quiet Apps"
                                )
                            }
                            .disclosureGroupStyle(.automatic)
                            .padding(.top, playingIDs.isEmpty ? 0 : 6)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(Constants.UI.edgePadding)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                SettingsSectionHeader("Master Volume")

                HStack(spacing: Constants.UI.interElementSpacing) {
                    Image(systemName: masterVolumeIconName)
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .animation(Constants.Motion.spring, value: masterVolumeIconName)

                    Slider(value: $masterVolume, in: 0.0...1.0)
                        .accessibilityLabel("Master volume")
                        .accessibilityValue("\(Int(masterVolume * 100)) percent")
                        .accessibilityHint("Adjusts the overall output volume of MixPill")

                    Text("\(Int(masterVolume * 100))%")
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                .frame(height: Constants.UI.controlHeight)
            }
            .onChange(of: masterVolume) {
                ChannelConfigStore.shared.setMasterVolume(masterVolume)
            }

            HStack(spacing: Constants.UI.interElementSpacing) {
                Button {
                    withAnimation(Constants.Motion.spring) {
                        presetManager.savePreset(
                            name: "Preset \(presetManager.presets.count + 1)",
                            apps: discoveryService.availableApps
                        )
                    }
                } label: {
                    Label("Save Preset", systemImage: "square.and.arrow.down")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("Save the current volume and mute state of all apps")

                Spacer()

                Menu {
                    ForEach(presetManager.presets) { preset in
                        Button(preset.name) {
                            presetManager.applyPreset(id: preset.id, to: discoveryService)
                        }
                    }
                } label: {
                    Label("Load Preset", systemImage: "square.and.arrow.up")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .disabled(presetManager.presets.isEmpty)
                .help("Restore a saved preset")
            }

            if GlobalHotkeyManager.shared.isEnabled && GlobalHotkeyManager.shared.isAccessibilityTrusted {
                // The shortcuts are the best thing in the app and were
                // previously mentioned nowhere outside Settings.
                HStack(spacing: 6) {
                    Image(systemName: "command")
                        .font(.system(size: 9, weight: .semibold))
                    Text("⌥ Scroll over any window to adjust it · ⌘⌥M to mute")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
            }
        }
        .padding(Constants.UI.edgePadding)
    }

    private var masterVolumeIconName: String {
        if masterVolume == 0 { return "speaker.slash.fill" }
        if masterVolume < 0.33 { return "speaker.wave.1.fill" }
        if masterVolume < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Actions

    private func openSettings() {
        NSApp.sendAction(#selector(AppDelegate.openSettingsWindow), to: nil, from: nil)
    }

    private func toggleFocusShield() {
        FocusShieldManager.shared.setActive(!FocusShieldManager.shared.isShieldActive)
    }

    private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func closeWindow() {
        NSApp.keyWindow?.performClose(nil)
    }
}

/// Shown only when the core reports that a tap actually failed. Deliberately
/// a banner rather than a wall: whatever is wrong with one app, the rest of
/// the mixer still works and the user should still be able to reach it.
private struct CaptureProblemBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Some audio couldn't be captured")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
        .padding(.horizontal, Constants.UI.edgePadding)
        .padding(.top, Constants.UI.interElementSpacing)
        .accessibilityElement(children: .combine)
    }
}
