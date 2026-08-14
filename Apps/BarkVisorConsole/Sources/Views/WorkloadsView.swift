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
        VStack(spacing: 0) {
            Picker("Filter", selection: $filter) {
                Text("All").tag("all")
                ForEach(["running", "failed", "degraded", "stopped"], id: \.self) { key in
                    Text(WorkloadHealth.label(key)).tag(key)
                }
            }
            .pickerStyle(.segmented)
            .padding()

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
                .bvListStyle()
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workload.name)
                        .font(.headline)
                    Text("\(workload.cpuCount) vCPU · \(workload.memoryMB) MB · \(osLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill.health(workload.resolvedHealth)
            }

            if !compact {
                HStack {
                    if workload.canStart {
                        Button("Start") {
                            Task { await model.startWorkload(workload) }
                        }
                        .bvProminentButton()
                        .disabled(model.actionIDs.contains(workload.id))
                    }
                    if workload.canStop {
                        Button("Stop") {
                            Task { await model.stopWorkload(workload) }
                        }
                        .bvGlassButton()
                        .disabled(model.actionIDs.contains(workload.id))
                        Button("Force stop", role: .destructive) {
                            Task { await model.stopWorkload(workload, force: true) }
                        }
                        .disabled(model.actionIDs.contains(workload.id))
                    }
                    Button("Console") { showVNCHint = true }
                        .bvGlassButton()
                    if let url = webURL {
                        Link("Open in web UI", destination: url)
                    }
                    if model.actionIDs.contains(workload.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .alert("Console", isPresented: $showVNCHint) {
            if let url = vncURL {
                Button("Open web console") { open(url) }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("VNC is not embedded in this native console. Use the web UI console for this workload.")
        }
    }

    private var osLabel: String {
        workload.vmType.localizedCaseInsensitiveContains("windows") ? "Windows" : "Linux"
    }

    private var webURL: URL? {
        model.connectedURL?.appending(path: "vms").appending(path: workload.id)
    }

    private var vncURL: URL? {
        webURL?.appending(path: "vnc")
    }

    private func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
