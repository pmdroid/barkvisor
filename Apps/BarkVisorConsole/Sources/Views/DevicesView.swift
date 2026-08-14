import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("This \(Copy.home.lowercased()) only lists Devices after the connected \(Copy.device.lowercased()) answers.")
                )
            } else {
                List(model.devices, selection: Binding(
                    get: { model.selectedDeviceID },
                    set: { next in
                        guard let next, let device = model.devices.first(where: { $0.hostId == next }) else { return }
                        Task { await model.select(device) }
                    }
                )) {
                    DeviceRow(device: $0, selected: $0.hostId == model.selectedDeviceID)
                        .tag($0.hostId)
                }
                .platformListStyle()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add a \(Copy.device)", systemImage: "plus") {
                    Task { await model.open(.settings) }
                }
            }
        }
    }
}

struct DeviceRow: View {
    var device: HomeDeviceHealthSnapshot
    var selected: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.secondary)
            }
            StatusLabel.reachability(device.isReachable)
        }
    }

    private var subtitle: String {
        var parts = [device.isSelf ? "This \(Copy.device)" : Copy.device, device.platformLabel, device.workloadLine]
        if device.isReachable, let resources = device.resources {
            if let cpu = resources.cpuLoadPercent {
                parts.append("CPU \(Int(cpu.rounded()))%")
            }
            if let used = resources.memoryUsedMB, let total = resources.memoryTotalMB {
                parts.append(String(format: "%.1f / %.0f GB", Double(used) / 1024, Double(total) / 1024))
            }
        }
        return parts.joined(separator: " · ")
    }
}
