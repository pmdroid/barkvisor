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
                    NavigationLink {
                        WorkloadDetailView(
                            workloadID: workload.id,
                            deviceID: model.selectedDevice?.hostId ?? "self",
                            fallbackWorkload: workload,
                            fallbackDevice: model.selectedDevice ?? .placeholderSelf
                        )
                    } label: {
                        WorkloadRow(workload: workload, compact: false)
                    }
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

struct WorkloadRow: View {
    @Environment(AppModel.self) private var model
    var workload: Workload
    var compact: Bool
    @State private var pendingForceStop = false

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
            if model.actionIDs.contains(workload.id) {
                ProgressView().controlSize(.small)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if !compact {
                if workload.canStart {
                    Button("Start") {
                        Task { await model.startWorkload(workload) }
                    }
                    .tint(.green)
                    .disabled(model.actionIDs.contains(workload.id))
                }
                if workload.canStop {
                    Button("Stop") {
                        Task { await model.stopWorkload(workload) }
                    }
                    .disabled(model.actionIDs.contains(workload.id))
                    Button("Force Stop", role: .destructive) {
                        pendingForceStop = true
                    }
                    .disabled(model.actionIDs.contains(workload.id))
                }
            }
        }
        .contextMenu {
            if !compact {
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
}
