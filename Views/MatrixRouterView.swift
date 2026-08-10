import SwiftUI

/// Where each app's audio comes out.
///
/// This was a matrix — one column per routing target, a radio button at
/// every intersection. That reads beautifully with two devices and falls
/// apart at exactly the hardware it was built for: a 64-channel interface
/// contributes 32 stereo pairs, so the grid became 33 columns and roughly
/// 4000 pt wide, scrolling in both axes, with the one tick you were looking
/// for somewhere off screen. Above a handful of targets the same job is
/// done better by one grouped menu per row — which is what the popover has
/// always used.
public struct MatrixRouterView: View {
    @Environment(AppDiscoveryService.self) private var discoveryService
    @Environment(CoreBridge.self) private var coreBridge

    /// Beyond this many targets the grid stops being readable.
    private static let gridColumnLimit = 6

    public init() {}

    private var usesGrid: Bool {
        coreBridge.routingColumns.count <= Self.gridColumnLimit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
            header

            systemOutputPicker

            if discoveryService.availableApps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "app.dashed")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No apps available to route.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if usesGrid {
                gridLayout
            } else {
                listLayout
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Constants.UI.interElementSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Routing")
                    .font(.system(size: 15, weight: .semibold))
                Text("Choose the output for each application. “System Default” follows whatever macOS is using.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // One control instead of a "Route All" link under every column
            // heading — which, on a wide interface, meant 33 of them.
            RoutingPicker(columns: coreBridge.routingColumns, selection: routeEverythingBinding) {
                Label("Send everything to…", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(discoveryService.availableApps.isEmpty)
            .help("Point every application at one output")
        }
        .padding(.bottom, 4)
    }

    /// Moving the macOS default output, from the one place where somebody
    /// is already thinking about where audio goes.
    ///
    /// The core has been able to do this since the beginning — the XPC call
    /// and its bridge wrapper were fully wired and simply had no caller.
    /// Anything left on "System Default" follows this, so changing it here
    /// beats sending people to Sound settings and back.
    private var systemOutputPicker: some View {
        HStack(spacing: Constants.UI.interElementSpacing) {
            Image(systemName: "hifispeaker")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text("System output")
                .font(.system(size: 13))

            Spacer()

            Picker("System output", selection: Binding(
                get: { coreBridge.defaultDeviceUID ?? "" },
                set: { uid in
                    guard !uid.isEmpty else { return }
                    coreBridge.setDefaultOutputDeviceUID(uid) { success in
                        if !success {
                            MixPillLog.error("MatrixRouterView: macOS refused the default output change to \(uid)")
                        }
                    }
                }
            )) {
                ForEach(coreBridge.devices, id: \.uid) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(coreBridge.devices.isEmpty)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    /// Routing every app at once, recorded as a single undoable step rather
    /// than one entry per application.
    private var routeEverythingBinding: Binding<String> {
        Binding(
            get: { "" },
            set: { pairID in
                guard !pairID.isEmpty else { return }
                let store = ChannelConfigStore.shared
                let bundleIDs = discoveryService.availableApps.map(\.id)
                let before = Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, store.routingPairID(for: $0)) })
                let name = coreBridge.routingColumns.displayName(for: pairID)

                store.setRoutingWithoutUndo(pairID: pairID, for: bundleIDs)
                MixerUndoManager.shared.recordTransaction(
                    label: "Send Everything to \(name)",
                    undo: {
                        for (bundleID, previous) in before {
                            store.setRoutingWithoutUndo(pairID: previous, for: [bundleID])
                        }
                    },
                    redo: { store.setRoutingWithoutUndo(pairID: pairID, for: bundleIDs) }
                )
            }
        )
    }

    // MARK: - Layouts

    /// One row per app with a grouped menu. Scales to any number of targets.
    private var listLayout: some View {
        Form {
            Section {
                ForEach(discoveryService.availableApps) { app in
                    RoutingListRow(
                        app: app,
                        columns: coreBridge.routingColumns,
                        selection: Binding(
                            get: { ChannelConfigStore.shared.routingPairID(for: app.id) },
                            set: { ChannelConfigStore.shared.setRouting(pairID: $0, for: app.id) }
                        )
                    )
                }
            } header: {
                SettingsSectionHeader("Applications")
            } footer: {
                Text("\(coreBridge.routingColumns.count - 1) output targets available. Pairs on a multi-channel interface are grouped under their device.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// The original matrix, kept for the two- or three-device case where
    /// seeing every app and every destination at once genuinely helps.
    private var gridLayout: some View {
        ScrollView([.horizontal, .vertical]) {
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                GridRow {
                    SettingsSectionHeader("Input App")
                        .frame(width: 150, alignment: .leading)

                    ForEach(coreBridge.routingColumns, id: \.pairID) { column in
                        Text(column.displayName)
                            .font(.system(size: Constants.UI.headerFontSize, weight: .bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(width: 120)
                    }
                }

                Divider()

                ForEach(discoveryService.availableApps) { app in
                    RoutingGridRow(
                        app: app,
                        columns: coreBridge.routingColumns,
                        currentPairID: ChannelConfigStore.shared.routingPairID(for: app.id),
                        onSelect: { ChannelConfigStore.shared.setRouting(pairID: $0, for: app.id) }
                    )
                    Divider().opacity(0.5)
                }
            }
        }
    }
}

private struct RoutingListRow: View {
    let app: AudioAppModel
    let columns: [RoutingColumnDTO]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: Constants.UI.interElementSpacing) {
            if let icon = app.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Text(app.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            Spacer()

            RoutingPicker(columns: columns, selection: $selection) {
                HStack(spacing: 4) {
                    Text(columns.displayName(for: selection))
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(selection == "system-default" ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Output for \(app.name)")
        }
    }
}

private struct RoutingGridRow: View {
    let app: AudioAppModel
    let columns: [RoutingColumnDTO]
    let currentPairID: String
    let onSelect: (String) -> Void

    @State private var isHovering = false

    var body: some View {
        GridRow {
            HStack(spacing: 6) {
                if let icon = app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 18, height: 18)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text(app.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)

            ForEach(columns, id: \.pairID) { column in
                let isSelected = currentPairID == column.pairID
                Button {
                    onSelect(column.pairID)
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.hierarchical)
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .symbolEffect(.bounce, value: isSelected)
                .frame(width: 120, alignment: .center)
                .help(isSelected ? "\(app.name) plays on \(column.displayName)" : "Route \(app.name) to \(column.displayName)")
                .accessibilityLabel("Route \(app.name) to \(column.displayName)")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
        .background(Color.primary.opacity(isHovering ? Constants.UI.hoverOpacity : 0))
        .onHover { hovering in
            withAnimation(Constants.Motion.spring) {
                isHovering = hovering
            }
        }
    }
}
