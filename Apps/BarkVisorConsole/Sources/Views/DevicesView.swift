import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: Copy.devices, subtitle: subtitle) {
                Button("Add a \(Copy.device)") {
                    Task { await model.open(.settings) }
                }
                .buttonStyle(BVButtonStyle(kind: .primary))
            }

            if model.devices.isEmpty {
                EmptyPanel(
                    title: "No Devices yet",
                    message: "This \(Copy.home.lowercased()) only lists Devices after the connected \(Copy.device.lowercased()) answers."
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], spacing: 16) {
                    ForEach(model.devices) { device in
                        Button {
                            Task { await model.select(device) }
                        } label: {
                            DeviceCard(device: device, selected: device.hostId == model.selectedDeviceID)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        if let totals = model.totals {
            var line = "\(totals.reachable) of \(totals.devices) reachable"
            if totals.unreachable > 0 { line += " · \(totals.unreachable) unreachable" }
            if let count = totals.workloadCount {
                line += " · \(count) workloads across this \(Copy.home)"
            }
            return line
        }
        return "Every \(Copy.device.lowercased()) in this \(Copy.home)"
    }
}

struct DeviceCard: View {
    var device: HomeDeviceHealthSnapshot
    var selected: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.title)
                        .font(BVTheme.font(16, weight: .bold))
                        .foregroundStyle(BVTheme.text)
                    HStack(spacing: 8) {
                        Text(device.isSelf ? "This \(Copy.device)" : Copy.device)
                            .font(BVTheme.font(10, weight: .semibold))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundStyle(device.isSelf ? BVTheme.green : BVTheme.textSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(device.isSelf ? BVTheme.greenMuted : BVTheme.bgHover)
                        Text(device.platformLabel)
                            .font(BVTheme.font(12))
                            .foregroundStyle(BVTheme.textDim)
                    }
                }
                Spacer()
                StatusPill.reachability(device.isReachable)
            }

            Text(device.workloadLine)
                .font(BVTheme.font(13))
                .foregroundStyle(BVTheme.textSecondary)

            if !device.isReachable {
                Text("This \(Copy.device.lowercased()) is still running locally. The member did not answer.")
                    .font(BVTheme.font(12))
                    .foregroundStyle(BVTheme.textDim)
            } else if let counts = device.healthCounts {
                HStack(spacing: 8) {
                    ForEach(WorkloadHealth.stripKeys, id: \.self) { key in
                        Text("\(counts[key] ?? 0) \(WorkloadHealth.label(key))")
                            .font(BVTheme.font(11))
                            .foregroundStyle(BVTheme.textDim)
                    }
                }
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
                .font(BVTheme.font(12))
                .foregroundStyle(BVTheme.textSecondary)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BVTheme.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: BVTheme.radius)
                .stroke(
                    selected ? BVTheme.accent.opacity(0.45) : (device.isReachable ? BVTheme.borderGlass : BVTheme.red.opacity(0.35)),
                    lineWidth: 1
                )
        )
    }
}
