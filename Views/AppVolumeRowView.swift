import SwiftUI

public struct AppVolumeRowView: View {
    @Binding var app: AudioAppModel
    var onVolumeChange: (Float, Bool) -> Void
    @Environment(CoreBridge.self) private var coreBridge
    @State private var showingEQ = false
    @State private var isHovering = false
    @State private var isDawDirect = false
    /// Mirrors the persisted routing so the menu's tick tracks it. Reading
    /// UserDefaults straight from `body` is invisible to SwiftUI, which is
    /// why the checkmark used to stay on whatever was selected at launch.
    @State private var routePairID = "system-default"

    /// Routing targets grouped by device, with "System Default" left
    /// ungrouped at the top. Keeps a 32-pair interface navigable.
    private struct RoutingGroup {
        let title: String
        let deviceName: String?
        let columns: [RoutingColumnDTO]
    }

    private var routingGroups: [RoutingGroup] {
        var groups: [RoutingGroup] = []
        var currentDevice: String?
        var buffer: [RoutingColumnDTO] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            groups.append(RoutingGroup(
                title: currentDevice ?? "system",
                deviceName: currentDevice,
                columns: buffer
            ))
            buffer = []
        }

        for column in coreBridge.routingColumns {
            if column.deviceName != currentDevice {
                flush()
                currentDevice = column.deviceName
            }
            buffer.append(column)
        }
        flush()
        return groups
    }

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

                        Spacer(minLength: 4)

                        if ChannelConfigStore.isDAW(bundleID: app.id) {
                            dawDirectButton
                        }

                        routingMenu

                        eqButton
                    }

                    HStack(spacing: Constants.UI.interElementSpacing) {
                        muteButton

                        Slider(value: Binding(
                            get: { app.volume },
                            set: { newValue in
                                app.volume = newValue
                                onVolumeChange(newValue, app.isMuted)
                            }
                        ), in: 0.0...1.0)
                        .accessibilityLabel("\(app.name) volume")
                        .accessibilityValue("\(Int(app.volume * 100)) percent")
                        .accessibilityHint("Adjusts the output volume of \(app.name)")

                        Text("\(Int(app.volume * 100))%")
                            .font(.system(size: 12, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            AudioLevelMeterView(level: app.audioLevel, peak: app.peakLevel)
                .padding(.leading, Constants.UI.iconSize + Constants.UI.interElementSpacing)
        }
        // Idle apps stay reachable but stop competing for attention. The
        // list is sorted playing-first by the core, so this reinforces an
        // order the eye is already following.
        .opacity(app.isPlaying ? 1.0 : 0.62)
        .animation(Constants.Motion.spring, value: app.isPlaying)
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
        .onAppear {
            isDawDirect = ChannelConfigStore.shared.isDawDirectMode(for: app.id)
            routePairID = ChannelConfigStore.shared.routingPairID(for: app.id)
        }
        .onChange(of: app.id) {
            // Rows are recycled across apps as the list changes.
            isDawDirect = ChannelConfigStore.shared.isDawDirectMode(for: app.id)
            routePairID = ChannelConfigStore.shared.routingPairID(for: app.id)
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
        .symbolEffect(
            .variableColor.iterative.reversing,
            options: .repeat(.continuous).speed(1.5),
            isActive: !app.isMuted && app.audioLevel > 0.02
        )
        .help(app.isMuted ? "Unmute" : "Mute")
        .accessibilityLabel(app.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
        .accessibilityHint(app.isMuted ? "Restores audio for \(app.name)" : "Silences \(app.name)")
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
        let currentName = coreBridge.routingColumns.first(where: { $0.pairID == routePairID })?.displayName ?? "System Default"

        // An inline `Picker` *inside* a `Menu`, rather than a bare Picker.
        //
        // The picker binds to state, so the tick follows the selection and
        // macOS draws it natively — that is the part hand-rolled checkmarks
        // got wrong. But a bare `Picker` also sizes itself to its widest
        // option, and a 64-channel interface contributes 32 entries reading
        // "Orion_32+_Gen4 — Outputs 63-64". That blew the 320 pt popover
        // wide open. Wrapping it in a Menu whose label is just the icon
        // keeps the control one glyph wide however long the list gets.
        return Menu {
            Picker("Output", selection: routingSelection) {
                ForEach(routingGroups, id: \.title) { group in
                    if let title = group.deviceName {
                        Section(title) {
                            ForEach(group.columns, id: \.pairID) { column in
                                Text(column.channelLabel ?? column.displayName).tag(column.pairID)
                            }
                        }
                    } else {
                        ForEach(group.columns, id: \.pairID) { column in
                            Text(column.displayName).tag(column.pairID)
                        }
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
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

    /// DAW Direct Bypass: shown only for detected DAWs (Logic, Live, Pro
    /// Tools, Cubase, FL Studio, Studio One). Bypasses EQ, gate and
    /// compression so the DAW's output reaches the interface untouched.
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
            ? "DAW Direct is on: MixPill leaves this app completely alone, so its own outputs, routing and monitoring latency are untouched."
            : "DAW Direct is off, so this app is mixed like any other. Turn it on to hand the app back its own output path.")
        .accessibilityLabel("DAW Direct for \(app.name)")
        .accessibilityHint("Stops MixPill capturing this app so its own routing and latency are unaffected")
    }

    private var speakerIconName: String {
        if app.volume == 0 { return "speaker.fill" }
        if app.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }
}
