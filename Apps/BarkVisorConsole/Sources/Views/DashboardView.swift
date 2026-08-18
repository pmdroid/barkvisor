import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            if let stats = model.stats {
                Section("This Device") {
                    LabeledContent("CPU", value: String(format: "%.0f%%", stats.hostCpuPercent))
                    LabeledContent("Memory", value: memoryLabel(used: stats.hostMemoryUsedMB, total: stats.hostMemoryTotalMB))
                    LabeledContent("Workloads running", value: "\(stats.runningVMs) / \(stats.totalVMs)")
                    LabeledContent("Devices reachable", value: "\(reachable) / \(model.devices.count)")
                }
            }

            if let counts = model.totals?.healthCounts {
                Section("Home health") {
                    ForEach(WorkloadHealth.stripKeys, id: \.self) { key in
                        LabeledContent(WorkloadHealth.label(key), value: "\(counts[key] ?? 0)")
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
                        NavigationLink {
                            WorkloadDetailView(
                                workloadID: workload.id,
                                deviceID: model.selectedDevice?.hostId ?? "self",
                                fallbackWorkload: workload,
                                fallbackDevice: model.selectedDevice ?? .placeholderSelf
                            )
                        } label: {
                            WorkloadRow(workload: workload)
                        }
                    }
                    Button("Open workloads") {
                        Task { await model.open(.workloads) }
                    }
                }
            }
        }
        .platformListStyle()
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
}
