import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var homeCanCreate = false

    var body: some View {
        Group {
            if model.devices.isEmpty {
                ContentUnavailableView(
                    "No Devices yet",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text("Connect to a \(Copy.home) to see workloads."),
                )
            } else if !model.homeLoaded {
                ProgressView("Loading workloads…")
            } else if model.homeRows.isEmpty, model.homeLoadErrors.isEmpty, allUnreachable {
                ContentUnavailableView(
                    "Devices unreachable",
                    systemImage: "wifi.exclamationmark",
                    description: Text("No reachable \(Copy.device.lowercased()) to list workloads from."),
                )
            } else {
                List {
                    Section(Copy.workloads) {
                        if model.homeRows.isEmpty {
                            Text(
                                canCreate
                                    ? "No workloads on reachable Devices. Create one from a Library image."
                                    : CreateWorkload.emptyLibraryCopy,
                            )
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
        .refreshable {
            await model.refreshHome()
            let ready = await model.anyReadyLibraryImage()
            guard !Task.isCancelled else { return }
            homeCanCreate = ready
        }
        .task(id: CreateWorkload.reachableDeviceKey(model.devices)) {
            let ready = await model.anyReadyLibraryImage()
            guard !Task.isCancelled else { return }
            homeCanCreate = ready
        }
        .createWorkloadEntry(
            allowsDevicePicker: true,
            images: model.images,
            enabled: canCreate,
        )
    }

    private var canCreate: Bool {
        homeCanCreate || CreateWorkload.hasReadyImage(model.images)
    }

    private var allUnreachable: Bool {
        !model.devices.isEmpty && model.devices.allSatisfy { !$0.isReachable }
    }
}

struct HomeWorkloadRowView: View {
    @Environment(AppModel.self) private var model
    var row: HomeWorkloadRow

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
        .workloadRowPowerActions(listActions) {
            Task { await model.startWorkload(row.workload, on: row.device) }
        } onStop: {
            Task { await model.stopWorkload(row.workload, on: row.device) }
        }
    }

    private var busy: Bool {
        model.actionIDs.contains(row.id)
    }

    private var listActions: [WorkloadListAction] {
        WorkloadListActions.resolve(
            workload: row.workload,
            deviceReachable: row.device.isReachable,
            inFlight: busy,
        )
    }
}
