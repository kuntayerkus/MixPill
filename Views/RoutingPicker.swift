import SwiftUI

/// Routing targets grouped by the device they belong to.
///
/// A 64-channel interface contributes 32 stereo pairs. As one flat list
/// that is unusable; as "Device ▸ Outputs 3-4" it is obvious. Shared by the
/// popover row and the Routing tab so the two can never drift.
struct RoutingGroup: Identifiable {
    let id: String
    let deviceName: String?
    let columns: [RoutingColumnDTO]

    static func grouped(_ columns: [RoutingColumnDTO]) -> [RoutingGroup] {
        var groups: [RoutingGroup] = []
        var currentDevice: String?
        var buffer: [RoutingColumnDTO] = []

        func flush() {
            guard !buffer.isEmpty else { return }
            groups.append(RoutingGroup(
                id: currentDevice ?? "system",
                deviceName: currentDevice,
                columns: buffer
            ))
            buffer = []
        }

        for column in columns {
            if column.deviceName != currentDevice {
                flush()
                currentDevice = column.deviceName
            }
            buffer.append(column)
        }
        flush()
        return groups
    }
}

/// A grouped output picker, wrapped in a `Menu` so the control stays the
/// width of its label however long the device list gets.
///
/// An inline `Picker` *inside* a `Menu`, rather than a bare Picker: the
/// picker binds to state, so the tick follows the selection and macOS draws
/// it natively — that is the part hand-rolled checkmarks got wrong. But a
/// bare `Picker` also sizes itself to its widest option, and 32 entries
/// reading "Orion_32+_Gen4 — Outputs 63-64" blew the 320 pt popover wide
/// open.
struct RoutingPicker<Label: View>: View {
    let columns: [RoutingColumnDTO]
    @Binding var selection: String
    @ViewBuilder var label: () -> Label

    var body: some View {
        Menu {
            Picker("Output", selection: $selection) {
                ForEach(RoutingGroup.grouped(columns)) { group in
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
            label()
        }
    }
}

extension Array where Element == RoutingColumnDTO {
    func displayName(for pairID: String) -> String {
        first(where: { $0.pairID == pairID })?.displayName ?? "System Default"
    }
}
