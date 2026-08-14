import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let stats = model.stats {
                Section("This Device") {
                    LabeledContent("CPU") {
                        Text(String(format: "%.0f%%", stats.hostCpuPercent))
                            .foregroundStyle(BVTheme.accent)
                            .monospacedDigit()
                    }
                    LabeledContent("Memory") {
                        Text(memoryLabel(used: stats.hostMemoryUsedMB, total: stats.hostMemoryTotalMB))
                            .monospacedDigit()
                    }
                    LabeledContent("Workloads running") {
                        Text("\(stats.runningVMs) / \(stats.totalVMs)")
                            .monospacedDigit()
                    }
                    LabeledContent("Devices reachable") {
                        Text("\(reachable) / \(model.devices.count)")
                            .monospacedDigit()
                    }
                }
            }

            if let counts = model.totals?.healthCounts {
                Section("Home health") {
                    ForEach(WorkloadHealth.stripKeys, id: \.self) { key in
                        LabeledContent(WorkloadHealth.label(key)) {
                            Text("\(counts[key] ?? 0)")
                                .foregroundStyle(pillColor(key))
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section(Copy.device) {
                if let device = model.selectedDevice {
                    NavigationLink {
                        DevicesView()
                    } label: {
                        DeviceRow(device: device)
                    }
                } else {
                    ContentUnavailableView(
                        "No Device selected",
                        systemImage: "externaldrive.badge.questionmark",
                        description: Text("Connect to a Home to see Devices.")
                    )
                }
            }

            Section("Recent workloads") {
                if recent.isEmpty {
                    ContentUnavailableView(
                        "No workloads",
                        systemImage: "display",
                        description: Text("This \(Copy.device.lowercased()) has no workloads yet.")
                    )
                } else {
                    ForEach(recent) { workload in
                        WorkloadRow(workload: workload, compact: true)
                    }
                    Button("Open workloads") {
                        Task { await model.open(.workloads) }
                    }
                }
            }
        }
        .bvListStyle()
    }

    private var reachable: Int {
        model.totals?.reachable ?? model.devices.filter(\.isReachable).count
    }

    private var recent: [Workload] {
        Array(model.workloads.sorted { $0.updatedAt > $1.updatedAt }.prefix(5))
    }

    private func memoryLabel(used: Int, total: Int) -> String {
        String(format: "%.1f / %.0f GB", Double(used) / 1024, Double(total) / 1024)
    }

    private func pillColor(_ key: String) -> Color {
        switch key {
        case "running": BVTheme.green
        case "failed": BVTheme.red
        case "starting", "degraded": BVTheme.amber
        default: .secondary
        }
    }
}
