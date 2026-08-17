import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

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
                    WorkloadRow(workload: workload, compact: false)
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
    @State private var showVNCHint = false
    @State private var pendingForceStop = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(workload.name)
                Text("\(workload.cpuCount) vCPU · \(workload.memoryMB) MB · \(osLabel)")
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
                Button("Console") { showVNCHint = true }
                if let url = webURL {
                    Link("Open in web UI", destination: url)
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
        .alert("Console", isPresented: $showVNCHint) {
            if let url = vncURL {
                Button(consoleButtonTitle) { open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(consoleMessage)
        }
    }

    private var osLabel: String {
        workload.vmType.localizedCaseInsensitiveContains("windows") ? "Windows" : "Linux"
    }

    private var webURL: URL? {
        guard let base = model.connectedURL else { return nil }
        return WorkloadWebLink.page(base: base, workloadID: workload.id, device: model.selectedDevice)
    }

    private var vncURL: URL? {
        guard let base = model.connectedURL else { return nil }
        return WorkloadWebLink.console(base: base, workloadID: workload.id, device: model.selectedDevice)
    }

    private var isMemberDevice: Bool {
        model.selectedDevice?.isSelf == false
    }

    private var consoleButtonTitle: String {
        isMemberDevice ? "Open Device page" : "Open web console"
    }

    private var consoleMessage: String {
        if isMemberDevice {
            return "Member Workload console is not a local /vms path. Open this Device in the web UI."
        }
        return "VNC is not embedded in this native console. Use the web UI console for this workload."
    }

    private func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
