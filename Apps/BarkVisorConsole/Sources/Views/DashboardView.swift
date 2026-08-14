import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(
                title: "Dashboard",
                subtitle: subtitle
            ) {
                HStack(spacing: 10) {
                    DevicePicker()
                    Button("Open workloads") {
                        Task { await model.open(.workloads) }
                    }
                    .buttonStyle(BVButtonStyle(kind: .primary))
                }
            }

            if let totals = model.totals {
                healthStrip(totals.healthCounts)
            }

            if let stats = model.stats {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], spacing: 12) {
                    statCard(
                        value: String(format: "%.0f%%", stats.hostCpuPercent),
                        label: "Device CPU",
                        accent: BVTheme.accent
                    )
                    statCard(
                        value: memoryLabel(used: stats.hostMemoryUsedMB, total: stats.hostMemoryTotalMB),
                        label: "Device memory",
                        accent: BVTheme.green
                    )
                    statCard(
                        value: "\(stats.runningVMs) / \(stats.totalVMs)",
                        label: "Workloads running",
                        accent: BVTheme.amber
                    )
                    statCard(
                        value: "\(model.totals?.reachable ?? model.devices.filter(\.isReachable).count) / \(model.devices.count)",
                        label: "Devices reachable",
                        accent: BVTheme.accent
                    )
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Selected \(Copy.device.lowercased())")
                    .font(BVTheme.font(16, weight: .semibold))
                if let device = model.selectedDevice {
                    DeviceCard(device: device)
                } else {
                    EmptyPanel(title: "No Device selected", message: "Connect to a Home to see Devices.")
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("Recent workloads")
                    .font(BVTheme.font(16, weight: .semibold))
                if model.workloads.isEmpty {
                    EmptyPanel(
                        title: "No workloads",
                        message: "This \(Copy.device.lowercased()) has no workloads yet."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(recent) { workload in
                            WorkloadRow(workload: workload, compact: true)
                        }
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let running = model.workloads.filter(\.isRunning).count
        let total = model.workloads.count
        var line = "\(running) of \(total) workloads running"
        if let name = model.selectedDevice?.title {
            line += " · \(name)"
        }
        return line
    }

    private var recent: [Workload] {
        Array(model.workloads.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    private func healthStrip(_ counts: [String: Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(WorkloadHealth.stripKeys, id: \.self) { key in
                HStack(spacing: 6) {
                    Text("\(counts[key] ?? 0)")
                        .font(BVTheme.font(16, weight: .bold))
                    Text(WorkloadHealth.label(key))
                        .font(BVTheme.font(11, weight: .semibold))
                }
                .foregroundStyle(pillColor(key))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(pillColor(key).opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
            }
        }
    }

    private func statCard(value: String, label: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value)
                .font(BVTheme.font(22, weight: .bold))
                .foregroundStyle(BVTheme.text)
            Text(label)
                .font(BVTheme.font(12, weight: .medium))
                .foregroundStyle(BVTheme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(BVTheme.bgCard)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: BVTheme.radius)
                .stroke(BVTheme.borderGlass, lineWidth: 1)
        )
    }

    private func memoryLabel(used: Int, total: Int) -> String {
        let usedGB = Double(used) / 1024
        let totalGB = Double(total) / 1024
        return String(format: "%.1f / %.0f GB", usedGB, totalGB)
    }

    private func pillColor(_ key: String) -> Color {
        switch key {
        case "running": BVTheme.green
        case "failed": BVTheme.red
        case "starting", "degraded": BVTheme.amber
        default: BVTheme.gray
        }
    }
}
