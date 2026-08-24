import Charts
import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    var deviceID: String
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var points: [DeviceStatsChartPoint] = []

    var body: some View {
        List {
            Section {
                LabeledContent("Platform", value: device.platformLabel)
                LabeledContent("Status") {
                    StatusLabel.reachability(device.isReachable)
                }
                LabeledContent(Copy.workloads, value: device.workloadLine)
                if let resources = device.resourcesLine {
                    LabeledContent("Resources", value: resources)
                }
            }

            if !DeviceStatsHistory.shouldFetch(device) {
                Section {
                    Text(DeviceStatsHistory.unreachableCopy)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("CPU") {
                    if points.count > 1 {
                        Chart(points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("CPU", point.cpuPercent),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("CPU", point.cpuPercent),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                        }
                        .chartYScale(domain: 0 ... 100)
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("CPU history")
                    }
                    LabeledContent("Now", value: cpuNow)
                }

                Section("Memory") {
                    if points.count > 1 {
                        Chart(points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Memory", point.memoryUsedGB),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.green.opacity(0.8))
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Memory", point.memoryUsedGB),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.green.opacity(0.12))
                        }
                        .chartYScale(domain: 0 ... memoryCeiling)
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("Memory history")
                    }
                    LabeledContent("Now", value: memoryNow)
                }
            }
        }
        .platformListStyle()
        .navigationTitle(device.title)
        .task(id: "\(deviceID)-\(device.role)-\(device.reachability)") {
            await model.select(device)
            await loadHistory()
        }
        .refreshable { await loadHistory() }
    }

    private var device: HomeDeviceHealthSnapshot {
        model.devices.first(where: { $0.hostId == deviceID }) ?? fallbackDevice
    }

    private var cpuNow: String {
        if let last = points.last {
            return String(format: "%.0f%%", last.cpuPercent)
        }
        if let cpu = device.resources?.cpuLoadPercent {
            return String(format: "%.0f%%", cpu)
        }
        return "—"
    }

    private var memoryNow: String {
        if let last = points.last {
            return String(format: "%.1f / %.0f GB", last.memoryUsedGB, last.memoryTotalGB)
        }
        if let used = device.resources?.memoryUsedMB, let total = device.resources?.memoryTotalMB {
            return String(format: "%.1f / %.0f GB", Double(used) / 1024, Double(total) / 1024)
        }
        return "—"
    }

    private var memoryCeiling: Double {
        max(points.last?.memoryTotalGB ?? 1, 1)
    }

    private func loadHistory() async {
        let target = device
        guard DeviceStatsHistory.shouldFetch(target) else {
            points = []
            return
        }
        points = DeviceStatsHistory.points(from: await model.statsHistory(on: target))
    }
}
