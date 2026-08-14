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
                .bvListStyle()
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(device.title)
                    .font(.headline)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(BVTheme.accent)
                        .imageScale(.small)
                }
                Spacer()
                StatusPill.reachability(device.isReachable)
            }
            HStack(spacing: 8) {
                Text(device.isSelf ? "This \(Copy.device)" : Copy.device)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(device.isSelf ? BVTheme.green : .secondary)
                Text(device.platformLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(device.workloadLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if !device.isReachable {
                Text("This \(Copy.device.lowercased()) is still running locally. The member did not answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let counts = device.healthCounts {
                Text(WorkloadHealth.stripKeys.map { "\(counts[$0] ?? 0) \(WorkloadHealth.label($0))" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if device.isReachable, let resources = device.resources {
                HStack(spacing: 12) {
                    if let cpu = resources.cpuLoadPercent {
                        Text("CPU \(Int(cpu.rounded()))%")
                    }
                    if let used = resources.memoryUsedMB, let total = resources.memoryTotalMB {
                        Text(String(format: "Mem %.1f / %.0f GB", Double(used) / 1024, Double(total) / 1024))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceCard: View {
    var device: HomeDeviceHealthSnapshot
    var selected: Bool = false

    var body: some View {
        DeviceRow(device: device, selected: selected)
    }
}
