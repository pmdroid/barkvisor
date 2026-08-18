import SwiftUI

struct WorkloadsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = "all"

    var body: some View {
        Group {
            if visible.isEmpty {
                ContentUnavailableView(
                    "No workloads",
                    systemImage: "display",
                    description: Text(
                        model.selectedDevice?.isReachable == false
                            ? "This \(Copy.device.lowercased()) is unreachable."
                            : "Create workloads in the web UI, then they appear here."
                    )
                )
            } else {
                List(visible) { workload in
                    WorkloadListRow(workload: workload)
                }
                .platformListStyle()
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Filter", selection: $filter) {
                    Text("All").tag("all")
                    ForEach(["running", "failed", "degraded", "stopped"], id: \.self) { key in
                        Text(WorkloadHealth.label(key)).tag(key)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    private var visible: [Workload] {
        if filter == "all" { return model.workloads }
        return model.workloads.filter { $0.resolvedHealth == filter }
    }
}

struct WorkloadListRow: View {
    @Environment(AppModel.self) private var model
    var workload: Workload
    @State private var pendingForceStop = false

    var body: some View {
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
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if workload.canStart {
                Button("Start") {
                    Task { await model.startWorkload(workload) }
                }
                .tint(.green)
                .disabled(busy)
            }
            if workload.canStop {
                Button("Stop") {
                    Task { await model.stopWorkload(workload) }
                }
                .disabled(busy)
                Button("Force Stop", role: .destructive) {
                    pendingForceStop = true
                }
                .disabled(busy)
            }
        }
        .contextMenu {
            if workload.canStart {
                Button("Start") {
                    Task { await model.startWorkload(workload) }
                }
            }
            if workload.canStop {
                Button("Stop") {
                    Task { await model.stopWorkload(workload) }
                }
                Button("Force Stop", role: .destructive) {
                    pendingForceStop = true
                }
            }
        }
        .alert("Force stop \(workload.name)?", isPresented: $pendingForceStop) {
            Button("Force Stop", role: .destructive) {
                Task { await model.stopWorkload(workload, force: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The guest will not shut down cleanly.")
        }
    }

    private var busy: Bool {
        WorkloadRow.isBusy(workload, model: model)
    }
}

struct WorkloadRow: View {
    @Environment(AppModel.self) private var model
    var workload: Workload

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workload.name)
                Text("\(workload.cpuCount) vCPU · \(workload.memoryMB) MB · \(workload.guestOSFamily)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusLabel.health(workload.resolvedHealth)
            if busy {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var busy: Bool {
        Self.isBusy(workload, model: model)
    }

    static func isBusy(_ workload: Workload, model: AppModel) -> Bool {
        let key = WorkloadActionKey.id(hostID: model.selectedDevice?.hostId, workloadID: workload.id)
        return model.actionIDs.contains(key) || model.actionIDs.contains(workload.id)
    }
}
