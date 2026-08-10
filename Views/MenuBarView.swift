import SwiftUI
import AppKit

public struct MenuBarView: View {
    @Environment(AppDiscoveryService.self) private var discoveryService
    @Environment(PresetManager.self) private var presetManager
    @Environment(CoreBridge.self) private var coreBridge

    @State private var searchText = ""
    @State private var masterVolume: Float = ChannelConfigStore.shared.masterVolume
    @State private var isMasterMuted = ChannelConfigStore.shared.isMasterMuted
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var showIdleApps = false
    /// Row the keyboard is on. Nil until someone actually uses the keyboard,
    /// so a mouse user never sees a selection they did not ask for.
    @State private var selectedID: String?
    @State private var isNamingPreset = false
    @State private var presetName = ""
    /// The list's own measured height, which is what the popover reserves
    /// for it. Starts at the floor so the first frame is not a sliver.
    @State private var contentHeight: CGFloat = MenuBarView.minimumListHeight

    private var playingIDs: Set<String> {
        Set(discoveryService.availableApps.filter(\.isPlaying).map(\.id))
    }

    private var idleIDs: Set<String> {
        Set(discoveryService.availableApps.filter { !$0.isPlaying }.map(\.id))
    }

    private func matchesSearch(_ app: AudioAppModel) -> Bool {
        searchText.isEmpty || app.name.localizedCaseInsensitiveContains(searchText)
    }

    /// Everything currently on screen, in the order it is drawn. Keyboard
    /// navigation walks this, so it can never disagree with what the eye
    /// is following.
    private var visibleApps: [AudioAppModel] {
        let playing = discoveryService.availableApps.filter { playingIDs.contains($0.id) && matchesSearch($0) }
        guard showIdleApps else { return playing }
        return playing + discoveryService.availableApps.filter { idleIDs.contains($0.id) && matchesSearch($0) }
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
            masterVolume = ChannelConfigStore.shared.masterVolume
            isMasterMuted = ChannelConfigStore.shared.isMasterMuted
        }
        .onDisappear {
            coreBridge.setMeterDisplayActive(false)
        }
        .alert("Save Preset", isPresented: $isNamingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { savePreset() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Captures every app's volume, mute, EQ, noise gate and output.")
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
                Image(systemName: focusShieldSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(focusShieldTint)
                    .frame(width: Constants.UI.controlHeight, height: Constants.UI.controlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .symbolEffect(.bounce, value: FocusShieldManager.shared.isShieldActive)
            .contentTransition(.symbolEffect(.replace))
            .help(focusShieldHelp)
            .accessibilityLabel("Focus Shield")
            .accessibilityValue(FocusShieldManager.shared.isAwaitingPermission
                ? "Waiting for Accessibility permission"
                : (FocusShieldManager.shared.isShieldActive ? "On" : "Off"))
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
                .onSubmit {
                    // Enter hands over to the list, so finding an app and
                    // then changing it never needs the mouse.
                    selectedID = visibleApps.first?.id
                    listFocused = true
                }
                .onChange(of: searchText) {
                    // Searching implies looking for something not in front
                    // of you, so open the quiet section rather than hiding
                    // the match inside a collapsed group.
                    if !searchText.isEmpty { showIdleApps = true }
                }

            ScrollViewReader { scroller in
                ScrollView {
                    VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
                        if discoveryService.availableApps.isEmpty {
                            // An empty list means one of two very different
                            // things, and they need different words. Either
                            // nothing is playing yet, or the audio engine
                            // never came up — in which case "Waiting for
                            // audio" is a reassurance that happens to be
                            // false.
                            emptyState
                        } else {
                            // Everything currently making sound, first and
                            // unadorned — that is what the popover was
                            // opened for.
                            if !playingIDs.isEmpty {
                                SettingsSectionHeader("Playing Now")
                            }
                            ForEach($discovery.availableApps) { $app in
                                if playingIDs.contains(app.id) && matchesSearch(app) {
                                    row(for: $app)
                                }
                            }

                            // Apps that have not made a sound recently are
                            // still reachable — their settings persist and
                            // matter — but they are folded away so a day's
                            // worth of launched apps does not bury the two
                            // that are playing.
                            if !idleIDs.isEmpty {
                                DisclosureGroup(isExpanded: $showIdleApps) {
                                    VStack(spacing: Constants.UI.interElementSpacing) {
                                        ForEach($discovery.availableApps) { $app in
                                            if idleIDs.contains(app.id) && matchesSearch(app) {
                                                row(for: $app)
                                            }
                                        }
                                    }
                                    .padding(.top, 4)
                                } label: {
                                    // Spelled out rather than using
                                    // inflection markup: `^[…](inflect:
                                    // true)` only resolves through a
                                    // localized string, and when it does not
                                    // it is shown to the user verbatim.
                                    SettingsSectionHeader(
                                        idleIDs.count == 1 ? "1 Quiet App" : "\(idleIDs.count) Quiet Apps"
                                    )
                                }
                                .disclosureGroupStyle(.automatic)
                                .padding(.top, playingIDs.isEmpty ? 0 : 6)
                            }
                        }
                    }
                    // Measured rather than estimated. The alternative is a
                    // per-row height constant, and a constant like that is
                    // wrong the first time anybody adds a control to a row.
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        contentHeight = height
                    }
                }
                .frame(height: listHeight)
                .focusable(!discoveryService.availableApps.isEmpty)
                .focused($listFocused)
                .onMoveCommand { direction in
                    handleMove(direction, scroller: scroller)
                }
                .onKeyPress("m") { toggleMuteOnSelection() }
                .onKeyPress("s") { toggleSoloOnSelection() }
                .accessibilityLabel("Application mixer")
            }
        }
        .padding(Constants.UI.edgePadding)
    }

    /// Grows with the list, and stops well short of the screen so the
    /// popover never becomes a wall.
    ///
    /// A **definite** height, not a `maxHeight`. A maximum is a ceiling and
    /// nothing else: it never asks for the space, and a `ScrollView` reports
    /// almost no height of its own along its scroll axis, so the popover
    /// sized itself to everything *except* the list and then handed the
    /// leftovers over. With a header, a search field, a master fader and a
    /// button row taking their share first, the leftovers were about a
    /// hundred points — one row, clipped, with four apps hidden behind a
    /// scrollbar in a window that had room for all of them.
    private var listHeight: CGFloat {
        min(max(contentHeight, Self.minimumListHeight), Self.maximumListHeight)
    }

    /// Enough for the empty state's icon and its sentence.
    private static let minimumListHeight: CGFloat = 150
    /// Past this the popover stops growing and the list starts scrolling.
    private static let maximumListHeight: CGFloat = 460

    @ViewBuilder
    private func row(for app: Binding<AudioAppModel>) -> some View {
        AppVolumeRowView(app: app) { volume, isMuted in
            ChannelConfigStore.shared.setVolume(volume, isMuted: isMuted, for: app.wrappedValue.id)
        }
        .id(app.wrappedValue.id)
        .overlay {
            // Only drawn once the keyboard is actually in use.
            if listFocused && selectedID == app.wrappedValue.id {
                RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Empty list, told apart by whether the core is actually answering.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: coreBridge.isConnected ? "waveform" : "bolt.horizontal.circle")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 26))
                .foregroundStyle(coreBridge.isConnected ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Color.orange))

            Text(coreBridge.isConnected ? "Waiting for audio" : "Can't reach the audio engine")
                .font(.system(size: 13, weight: .medium))

            Text(coreBridge.isConnected
                 ? "Play something in any app and it appears here with its own volume."
                 : "MixPill's audio service isn't answering. Reconnecting — if this keeps up, open Settings › Diagnostics and reset the engine.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if !coreBridge.isConnected {
                Button("Open Diagnostics") { openSettings() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 8)
        .animation(Constants.Motion.spring, value: coreBridge.isConnected)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    SettingsSectionHeader("Master Volume")
                    Spacer(minLength: 0)
                    if coreBridge.limiterReductionDB > Constants.UI.limiterVisibleDB {
                        limiterBadge
                    } else {
                        // Where the fader ends, said out loud. A ceiling
                        // you only discover by hitting it reads as a fault.
                        Text("0 dB max")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .animation(
                    Constants.Motion.spring,
                    value: coreBridge.limiterReductionDB > Constants.UI.limiterVisibleDB
                )

                HStack(spacing: Constants.UI.interElementSpacing) {
                    Button(action: toggleMasterMute) {
                        Image(systemName: isMasterMuted ? "speaker.slash.fill" : masterVolumeIconName)
                            .symbolRenderingMode(.hierarchical)
                            .contentTransition(.symbolEffect(.replace))
                            .foregroundStyle(isMasterMuted ? Color.red : Color.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .animation(Constants.Motion.spring, value: isMasterMuted)
                    .help(isMasterMuted ? "Unmute everything" : "Mute everything")
                    .accessibilityLabel(isMasterMuted ? "Unmute MixPill" : "Mute MixPill")

                    // Same dB taper as the channel faders, but without the
                    // boost region: the master sits after the sum, so
                    // pushing it above unity only feeds the limiter.
                    //
                    // That ceiling used to be invisible, which made it look
                    // like a bug — the fader reached the end and the sound
                    // stopped getting louder, with nothing on screen saying
                    // it was ever going to. Adding boost here would be the
                    // worse fix: it would move, and it would not work. So
                    // the ceiling is stated instead, and pointed at the
                    // place where boost actually exists.
                    Slider(value: Binding(
                        get: { AudioScale.position(forGain: masterVolume, allowBoost: false) },
                        set: { masterVolume = AudioScale.gain(forPosition: $0, allowBoost: false) }
                    ), in: 0.0...1.0)
                    .disabled(isMasterMuted)
                    .help("The master tops out at 0 dB — it sits after the mix, so raising it past unity would only feed the limiter. To make one app louder than the rest, push its own fader past unity.")
                    .accessibilityLabel("Master volume")
                    .accessibilityValue("\(AudioScale.faderLabel(forGain: masterVolume)), \(AudioScale.percentOfUnity(forGain: masterVolume)) percent")
                    .accessibilityHint("Adjusts the overall output volume of MixPill. Maximum is 0 decibels; boost above unity is on each app's own fader.")

                    Text(isMasterMuted ? "Muted" : AudioScale.faderLabel(forGain: masterVolume))
                        .font(.system(size: 11, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isMasterMuted ? Color.red : Color.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .frame(height: Constants.UI.controlHeight)
            }
            .onChange(of: masterVolume) {
                ChannelConfigStore.shared.setMasterVolume(masterVolume)
            }

            HStack(spacing: Constants.UI.interElementSpacing) {
                Button {
                    presetName = presetManager.suggestedName()
                    isNamingPreset = true
                } label: {
                    Label("Save Preset", systemImage: "square.and.arrow.down")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .help("Save every app's volume, mute, EQ, noise gate and output under a name")

                Spacer()

                Menu {
                    let activeID = presetManager.activePresetID()
                    ForEach(presetManager.presets) { preset in
                        Button {
                            withAnimation(Constants.Motion.spring) {
                                presetManager.applyPreset(id: preset.id, to: discoveryService)
                            }
                        } label: {
                            // A tick on the one already in effect: without
                            // it a list of saved presets says nothing about
                            // where you currently are.
                            if preset.id == activeID {
                                Label(preset.name, systemImage: "checkmark")
                            } else {
                                Text(preset.name)
                            }
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

            // Undo used to build a label for every change and show it
            // nowhere; the app has no menu bar, so ⌘Z was undiscoverable.
            if MixerUndoManager.shared.canUndo, let label = MixerUndoManager.shared.undoLabel {
                Button(action: MixerUndoManager.shared.performUndo) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Undo \(label)")
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Text("⌘Z")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.quaternary)
                    }
                    .foregroundStyle(.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .transition(.opacity)
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
        .animation(Constants.Motion.spring, value: MixerUndoManager.shared.canUndo)
    }

    /// The limiter, when it is doing something.
    ///
    /// Shown next to the master because it answers the one question the
    /// stage otherwise raises silently: a channel pushed into boost on
    /// already-loud material gets quieter treatment, not more loudness, and
    /// without this the fader simply looks broken.
    private var limiterBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.down.forward.and.arrow.up.backward")
                .font(.system(size: 9, weight: .semibold))
            Text(String(format: "−%.1f dB", coreBridge.limiterReductionDB))
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.orange.opacity(0.12), in: Capsule())
        .help("The mix is already at full scale, so MixPill is holding it back by this much. Turning a channel up further makes it louder than the others, not louder overall.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Limiter active")
        .accessibilityValue(String(format: "reducing the mix by %.1f decibels", coreBridge.limiterReductionDB))
        .transition(.opacity)
    }

    private var masterVolumeIconName: String {
        let position = AudioScale.position(forGain: masterVolume, allowBoost: false)
        if position <= 0 { return "speaker.slash.fill" }
        if position < 0.4 { return "speaker.wave.1.fill" }
        if position < 0.75 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - Keyboard navigation

    private func handleMove(_ direction: MoveCommandDirection, scroller: ScrollViewProxy) {
        let apps = visibleApps
        guard !apps.isEmpty else { return }

        switch direction {
        case .up, .down:
            let step = direction == .down ? 1 : -1
            let current = apps.firstIndex { $0.id == selectedID } ?? (direction == .down ? -1 : apps.count)
            let next = min(max(current + step, 0), apps.count - 1)
            selectedID = apps[next].id
            withAnimation(Constants.Motion.spring) {
                scroller.scrollTo(apps[next].id, anchor: .center)
            }

        case .left, .right:
            // A notch of fader travel, so a step feels the same wherever
            // the fader happens to be sitting.
            guard let selectedID else { return }
            let store = ChannelConfigStore.shared
            let updated = store.adjustVolume(by: direction == .right ? 0.03 : -0.03, for: selectedID)
            discoveryService.refreshModelFromStore(for: selectedID)
            _ = updated

        @unknown default:
            break
        }
    }

    private func toggleMuteOnSelection() -> KeyPress.Result {
        guard let selectedID else { return .ignored }
        ChannelConfigStore.shared.toggleMute(for: selectedID)
        discoveryService.refreshModelFromStore(for: selectedID)
        return .handled
    }

    private func toggleSoloOnSelection() -> KeyPress.Result {
        guard let selectedID else { return .ignored }
        ChannelConfigStore.shared.toggleSolo(for: selectedID)
        return .handled
    }

    // MARK: - Actions

    private func savePreset() {
        let trimmed = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? presetManager.suggestedName() : trimmed
        _ = withAnimation(Constants.Motion.spring) {
            presetManager.savePreset(name: name, apps: discoveryService.availableApps)
        }
    }

    private func toggleMasterMute() {
        isMasterMuted.toggle()
        ChannelConfigStore.shared.setMasterMuted(isMasterMuted)
    }

    private func openSettings() {
        NSApp.sendAction(#selector(AppDelegate.openSettingsWindow), to: nil, from: nil)
    }

    /// The shield has three states, and an on/off glyph could only show
    /// two. The third — asked for, waiting on macOS — is the one that used
    /// to look like a switch that refused to move.
    private var focusShieldSymbol: String {
        if FocusShieldManager.shared.isAwaitingPermission { return "exclamationmark.shield" }
        return FocusShieldManager.shared.isShieldActive ? "shield.fill" : "shield"
    }

    private var focusShieldTint: Color {
        if FocusShieldManager.shared.isAwaitingPermission { return .orange }
        return FocusShieldManager.shared.isShieldActive ? Color.accentColor : Color.secondary
    }

    /// `LocalizedStringKey`, not `String`: `.help(someString)` is the
    /// *non-localizing* overload, and moving these three lines behind a
    /// property would otherwise have quietly dropped two of them out of the
    /// String Catalog — translations included.
    private var focusShieldHelp: LocalizedStringKey {
        if FocusShieldManager.shared.isAwaitingPermission {
            return "Focus Shield is waiting for permission. Allow MixPill in System Settings › Privacy & Security › Accessibility and it turns itself on. Click to cancel."
        }
        return FocusShieldManager.shared.isShieldActive
            ? "Focus Shield is on: background apps cannot steal keyboard focus"
            : "Focus Shield is off: click to block background apps from stealing keyboard focus"
    }

    private func toggleFocusShield() {
        let shield = FocusShieldManager.shared
        // A pending request already reads as "on" to the user, so a click
        // withdraws it rather than asking macOS a question it has been
        // asked once and will not answer twice.
        shield.setActive(!(shield.isShieldActive || shield.isAwaitingPermission))
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
