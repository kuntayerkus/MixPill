import SwiftUI

/// Real routing matrix backed by the MixPillCore device registry.
/// Each app's channel strip can be pinned to a specific output device —
/// or to a specific channel pair on a multi-channel interface — or left
/// on "System Default" to follow the macOS default output.
public struct MatrixRouterView: View {
    @Environment(AppDiscoveryService.self) private var discoveryService
    @Environment(CoreBridge.self) private var coreBridge

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Constants.UI.interElementSpacing) {
            HStack(alignment: .top, spacing: Constants.UI.interElementSpacing) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routing Matrix")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Choose the output device for each application. “System Default” follows the macOS default output.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.bottom, 4)

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
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                        GridRow {
                            SettingsSectionHeader("Input App")
                                .frame(width: 150, alignment: .leading)

                            ForEach(coreBridge.routingColumns, id: \.pairID) { column in
                                VStack(spacing: 4) {
                                    Text(column.displayName)
                                        .font(.system(size: Constants.UI.headerFontSize, weight: .bold))
                                        .foregroundStyle(.secondary)
                                        .textCase(.uppercase)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(width: 120)

                                    Button {
                                        ChannelConfigStore.shared.setRouting(
                                            pairID: column.pairID,
                                            forAllApps: discoveryService.availableApps.map(\.id)
                                        )
                                    } label: {
                                        Text("Route All")
                                            .font(.system(size: 11, weight: .medium))
                                    }
                                    .buttonStyle(.link)
                                    .accessibilityLabel("Route all apps to \(column.displayName)")
                                }
                            }
                        }

                        Divider()

                        ForEach(discoveryService.availableApps) { app in
                            RoutingRow(
                                app: app,
                                columns: coreBridge.routingColumns,
                                currentPairID: ChannelConfigStore.shared.routingPairID(for: app.id),
                                onSelect: { pairID in
                                    ChannelConfigStore.shared.setRouting(pairID: pairID, for: app.id)
                                }
                            )
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 400)
    }
}

private struct RoutingRow: View {
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
