import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Connect to a \(Copy.home) to see workloads.")
                )
            } else if !model.homeLoaded {
                ProgressView("Loading workloads…")
            } else if model.homeRows.isEmpty, model.homeLoadErrors.isEmpty, allUnreachable {
                ContentUnavailableView(
                    "Devices unreachable",
                    systemImage: "wifi.exclamationmark",
                    description: Text("No reachable \(Copy.device.lowercased()) to list workloads from.")
                )
            } else {
                List {
                    Section(Copy.workloads) {
                        if model.homeRows.isEmpty {
                            Text("No workloads on reachable Devices.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(model.homeRows) { row in
                                HomeWorkloadRowView(row: row)
                            }
                        }
                    }
                    if !model.homeLoadErrors.isEmpty {
                        Section("Could not load") {
                            ForEach(model.homeLoadErrors) { error in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(error.device.title)
                                    Text(error.message)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if !model.homeUnreachable.isEmpty {
                        Section("Unreachable") {
                            ForEach(model.homeUnreachable) { device in
                                DeviceRow(device: device)
                            }
                        }
                    }
                }
                .platformListStyle()
            }
        }
        .refreshable { await model.refreshHome() }
    }

    private var allUnreachable: Bool {
        !model.devices.isEmpty && model.devices.allSatisfy { !$0.isReachable }
    }
}

struct HomeWorkloadRowView: View {
    @Environment(AppModel.self) private var model
    var row: HomeWorkloadRow
    @State private var pendingForceStop = false

    var body: some View {
        NavigationLink {
            WorkloadDetailView(row: row)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.workload.name)
                    Text("\(row.device.title) · \(row.workload.cpuCount) vCPU · \(row.workload.memoryMB) MB")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusLabel.health(row.workload.resolvedHealth)
                if busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.workload.canStart {
                Button("Start") {
                    Task { await model.startWorkload(row.workload, on: row.device) }
                }
                .tint(.green)
                .disabled(busy)
            }
            if row.workload.canStop {
                Button("Stop") {
                    Task { await model.stopWorkload(row.workload, on: row.device) }
                }
                .disabled(busy)
                Button("Force Stop", role: .destructive) {
                    pendingForceStop = true
                }
                .disabled(busy)
            }
        }
        .contextMenu {
            if row.workload.canStart {
                Button("Start") {
                    Task { await model.startWorkload(row.workload, on: row.device) }
                }
            }
            if row.workload.canStop {
                Button("Stop") {
                    Task { await model.stopWorkload(row.workload, on: row.device) }
                }
                Button("Force Stop", role: .destructive) {
                    pendingForceStop = true
                }
            }
        }
        .alert("Force stop \(row.workload.name)?", isPresented: $pendingForceStop) {
            Button("Force Stop", role: .destructive) {
                Task { await model.stopWorkload(row.workload, force: true, on: row.device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The guest will not shut down cleanly.")
        }
    }

    private var busy: Bool {
        model.actionIDs.contains(row.id)
    }
}
