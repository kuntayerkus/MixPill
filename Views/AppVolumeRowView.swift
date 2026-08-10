import SwiftUI

public struct AppVolumeRowView: View {
    @Binding var app: AudioAppModel
    var onVolumeChange: (Float, Bool) -> Void
    @Environment(CoreBridge.self) private var coreBridge
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingEQ = false
    @State private var isHovering = false
    @State private var isDawDirect = false
    /// Mirrors the persisted routing so the menu's tick tracks it. Reading
    /// UserDefaults straight from `body` is invisible to SwiftUI, which is
    /// why the checkmark used to stay on whatever was selected at launch.
    @State private var routePairID = "system-default"

    private var routingSelection: Binding<String> {
        Binding(
            get: { routePairID },
            set: { newValue in
                routePairID = newValue
                ChannelConfigStore.shared.setRouting(pairID: newValue, for: app.id)
            }
        )
    }

    public init(app: Binding<AudioAppModel>, onVolumeChange: @escaping (Float, Bool) -> Void) {
        self._app = app
        self.onVolumeChange = onVolumeChange
    }

    public var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: Constants.UI.interElementSpacing) {
                appIcon

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            // The name yields before the controls do.
                            .layoutPriority(-1)

                        if app.isCapturingInput {
                            // Explains, at a glance, why everything else
                            // just got quieter.
                            Image(systemName: "mic.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.green)
                                .help("On a call — other apps duck while this one is speaking")
                                .accessibilityLabel("\(app.name) is using the microphone")
                        }

                        if !app.isCaptured {
                            uncontrolledBadge
                        }

                        Spacer(minLength: 4)

                        // Shown for every app, not just recognised DAWs.
                        // Any application that routes to several outputs at
                        // once — a broadcast tool, a multi-output player —
                        // needs the same escape hatch, and a DAW needs to be
                        // able to come back out of it.
                        dawDirectButton

                        routingMenu

                        eqButton
                    }

                    HStack(spacing: Constants.UI.interElementSpacing) {
                        muteButton

                        soloButton

                        // The knob travels on a dB scale with unity at 80%
                        // and 6 dB of boost above it; the model still holds
                        // linear gain, so nothing downstream changes.
                        Slider(value: Binding(
                            get: { AudioScale.position(forGain: app.volume) },
                            set: { position in
                                let gain = AudioScale.gain(forPosition: position)
                                app.volume = gain
                                onVolumeChange(gain, app.isMuted)
                            }
                        ), in: 0.0...1.0)
                        .accessibilityLabel("\(app.name) volume")
                        .accessibilityValue("\(AudioScale.faderLabel(forGain: app.volume)), \(AudioScale.percentOfUnity(forGain: app.volume)) percent of normal")
                        .accessibilityHint("Adjusts the output volume of \(app.name)")

                        Text(AudioScale.faderLabel(forGain: app.volume))
                            .font(.system(size: 11, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(app.volume > 1.0 ? Color.accentColor : Color.secondary)
                            .frame(width: 52, alignment: .trailing)
                            .help("\(AudioScale.percentOfUnity(forGain: app.volume))% of normal volume")
                    }
                    // MixPill is not in this app's signal path, so none of
                    // these controls reach the sound. Leaving them live
                    // means a fader that moves and changes nothing.
                    .disabled(!app.isCaptured)
                    .modifier(ConditionalHelp(text: app.isCaptured ? nil : uncontrolledExplanation))
                }
            }

            AudioLevelMeterView(level: app.audioLevel, peak: app.peakLevel)
                .padding(.leading, Constants.UI.iconSize + Constants.UI.interElementSpacing)
        }
        // Idle apps stay reachable but stop competing for attention. The
        // list is sorted playing-first by the core, so this reinforces an
        // order the eye is already following. A channel silenced by
        // somebody else's solo fades further, because its mute button
        // correctly still reads "unmuted" — the solo is an overlay, not a
        // change to its saved state.
        .opacity(rowOpacity)
        .animation(Constants.Motion.spring, value: rowOpacity)
        .padding(.vertical, Constants.UI.interElementSpacing)
        .padding(.horizontal, Constants.UI.edgePadding)
        .background {
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                .fill(Color.primary.opacity(isHovering ? Constants.UI.hoverOpacity : Constants.UI.cardOpacity))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Constants.UI.cornerRadius)
                .strokeBorder(Color.primary.opacity(isHovering ? 0.08 : 0.04), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Constants.UI.cornerRadius))
        .onHover { hovering in
            withAnimation(Constants.Motion.spring) {
                isHovering = hovering
            }
        }
        .onAppear(perform: loadPersistedState)
        .onChange(of: app.id) {
            // Rows are recycled across apps as the list changes.
            loadPersistedState()
        }
        .animation(Constants.Motion.spring, value: app.isMuted)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(app.name) audio controls")
        .accessibilityValue(app.isPlaying ? "Playing" : "Idle")
    }

    // MARK: - Subviews

    private var appIcon: some View {
        Group {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: Constants.UI.iconSize, height: Constants.UI.iconSize)
            } else {
                Image(systemName: "app.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .frame(width: Constants.UI.iconSize, height: Constants.UI.iconSize)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var muteButton: some View {
        Button(action: {
            app.isMuted.toggle()
            onVolumeChange(app.volume, app.isMuted)
        }) {
            Image(systemName: app.isMuted ? "speaker.slash.fill" : speakerIconName)
                .symbolRenderingMode(.hierarchical)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 14))
                .foregroundStyle(app.isMuted ? Color.red : Color.primary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: app.isMuted)
        // A never-ending animation per playing row is exactly what Reduce
        // Motion is asking us not to do — and it keeps the display awake
        // for as long as anything is playing.
        .symbolEffect(
            .variableColor.iterative.reversing,
            options: .repeat(.continuous).speed(1.5),
            isActive: !reduceMotion && !app.isMuted && app.audioLevel > 0.02
        )
        .help(app.isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityHint(app.isMuted ? "Restores audio for \(app.name)" : "Silences \(app.name)")
    }

    private var isSilencedBySolo: Bool {
        let soloed = ChannelConfigStore.shared.soloedBundleID
        return soloed != nil && soloed != app.id
    }

    private var rowOpacity: Double {
        if isSilencedBySolo { return 0.4 }
        return app.isPlaying ? 1.0 : 0.62
    }

    /// Solo: hear this one and nothing else, without touching anybody's
    /// saved mute state.
    ///
    /// The counterpart to mute, and the move a mixer is actually used for —
    /// "which of these six things is making that noise?". It is a session
    /// state, not a setting: quitting MixPill or soloing something else
    /// puts every other channel straight back where it was.
    private var soloButton: some View {
        let isSoloed = ChannelConfigStore.shared.soloedBundleID == app.id
        return Button {
            ChannelConfigStore.shared.toggleSolo(for: app.id)
        } label: {
            Image(systemName: "headphones")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13))
                .foregroundStyle(isSoloed ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: isSoloed)
        .help(isSoloed ? "Stop soloing \(app.name)" : "Solo \(app.name) — silence everything else")
        .accessibilityLabel(isSoloed ? "Stop soloing \(app.name)" : "Solo \(app.name)")
        .accessibilityAddTraits(isSoloed ? .isSelected : [])
    }

    /// Says, in the row itself, that this channel's controls are inert —
    /// and which of the two reasons applies.
    private var uncontrolledBadge: some View {
        Text(isDawDirect ? "Direct" : "Not captured")
            .font(.system(size: 9, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(isDawDirect ? Color.secondary : Color.orange)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule().fill((isDawDirect ? Color.secondary : Color.orange).opacity(0.14))
            )
            .help(uncontrolledExplanation)
            .accessibilityLabel(isDawDirect
                ? "\(app.name) plays directly; MixPill is not controlling it"
                : "\(app.name) could not be captured; MixPill is not controlling it")
    }

    private var uncontrolledExplanation: String {
        isDawDirect
            ? "DAW Direct is on, so \(app.name) plays straight to your interface. MixPill is not in its signal path and these controls do nothing."
            : "MixPill could not capture \(app.name), so it is playing on its own and these controls do nothing. The engine keeps retrying."
    }

    private var eqButton: some View {
        Button(action: { showingEQ.toggle() }) {
            Image(systemName: "slider.vertical.3")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(showingEQ ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: showingEQ)
        .popover(isPresented: $showingEQ) {
            AdvancedEQView(bundleID: app.id)
        }
        .help("Equalizer & Noise Gate")
        .accessibilityLabel("Equalizer for \(app.name)")
        .accessibilityHint("Opens the 5-band equalizer and noise gate")
    }

    /// Per-app output device picker: pins this app to a specific device —
    /// or a specific channel pair on multi-channel interfaces — or leaves
    /// it following the system default.
    private var routingMenu: some View {
        let isPinned = routePairID != "system-default"
        let currentName = coreBridge.routingColumns.displayName(for: routePairID)

        return RoutingPicker(columns: coreBridge.routingColumns, selection: routingSelection) {
            Image(systemName: "airplayaudio")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .animation(Constants.Motion.spring, value: isPinned)
        .help("Output: \(currentName)")
        .accessibilityLabel("Output device for \(app.name)")
        .accessibilityHint("Pins \(app.name) to a specific audio output device or channel pair")
    }

    /// DAW Direct: stop capturing this app entirely, handing it back its own
    /// output path — its own routing, its own monitoring latency, its own
    /// multi-output setup.
    ///
    /// Offered on every row. Recognised DAWs (Logic, Live, Pro Tools,
    /// Cubase, FL Studio, Studio One…) default to on, but the switch is the
    /// user's: anything that routes to more than the one stereo pair MixPill
    /// replays wants it, and a DAW someone deliberately wants in the mix can
    /// now be turned back on.
    private var dawDirectButton: some View {
        Button {
            isDawDirect.toggle()
            ChannelConfigStore.shared.setDawDirectMode(enabled: isDawDirect, for: app.id)
        } label: {
            Image(systemName: "cable.connector")
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDawDirect ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .symbolEffect(.bounce, value: isDawDirect)
        .animation(Constants.Motion.spring, value: isDawDirect)
        .help(isDawDirect
            ? "DAW Direct is on: MixPill leaves \(app.name) completely alone, so its own outputs, routing and monitoring latency are untouched. Turn it off to mix it here."
            : "DAW Direct is off, so \(app.name) is mixed like any other app. Turn it on to hand it back its own output path.")
        .accessibilityLabel("DAW Direct for \(app.name)")
        .accessibilityHint("Stops MixPill capturing this app so its own routing and latency are unaffected")
    }

    /// Pulls the persisted per-app state the row shows but does not own.
    ///
    /// `routePairID` used to be left at its `@State` default forever, so an
    /// app pinned to a specific interface always drew "System Default" with
    /// an unlit icon — the audio went to the right place and the interface
    /// said otherwise. Reading `UserDefaults` inside `body` is invisible to
    /// SwiftUI, which is why these are mirrored into state here instead.
    private func loadPersistedState() {
        let store = ChannelConfigStore.shared
        isDawDirect = store.isDawDirectMode(for: app.id)
        routePairID = store.routingPairID(for: app.id)
    }

    private var speakerIconName: String {
        let position = AudioScale.position(forGain: app.volume)
        if position <= 0 { return "speaker.fill" }
        if position < 0.45 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}
