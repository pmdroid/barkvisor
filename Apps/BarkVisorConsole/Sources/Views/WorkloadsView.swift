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
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: Copy.workloads, subtitle: subtitle) {
                DevicePicker()
            }

            HStack(spacing: 4) {
                filterChip("all", label: "All")
                ForEach(["running", "failed", "degraded", "stopped"], id: \.self) { key in
                    filterChip(key, label: WorkloadHealth.label(key))
                }
            }
            .padding(4)
            .background(BVTheme.bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: BVTheme.radius)
                    .stroke(BVTheme.borderGlass, lineWidth: 1)
            )

            if visible.isEmpty {
                EmptyPanel(
                    title: "No workloads",
                    message: model.selectedDevice?.isReachable == false
                        ? "This \(Copy.device.lowercased()) is unreachable."
                        : "Create workloads in the web UI, then they appear here."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(visible) { workload in
                        WorkloadRow(workload: workload, compact: false)
                    }
                }
            }
        }
    }

    private var subtitle: String {
        let name = model.selectedDevice?.title ?? Copy.device
        return "\(visible.count) on \(name)"
    }

    private var visible: [Workload] {
        if filter == "all" { return model.workloads }
        return model.workloads.filter { $0.resolvedHealth == filter }
    }

    private func filterChip(_ key: String, label: String) -> some View {
        let active = filter == key
        return Button(label) { filter = key }
            .font(BVTheme.font(13, weight: .semibold))
            .foregroundStyle(active ? .white : BVTheme.textDim)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(active ? BVTheme.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: BVTheme.radius))
            .buttonStyle(.plain)
    }
}

struct WorkloadRow: View {
    @Environment(AppModel.self) private var model
    var workload: Workload
    var compact: Bool
    @State private var showVNCHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(workload.name)
                        .font(BVTheme.font(16, weight: .bold))
                    HStack(spacing: 8) {
                        Text("\(workload.cpuCount) vCPU")
                        Text("\(workload.memoryMB) MB")
                        Text(osLabel)
                    }
                    .font(BVTheme.font(12))
                    .foregroundStyle(BVTheme.textDim)
                }
                Spacer()
                StatusPill.health(workload.resolvedHealth)
            }

            if !compact {
                HStack(spacing: 8) {
                    if workload.canStart {
                        Button("Start") {
                            Task { await model.startWorkload(workload) }
                        }
                        .buttonStyle(BVButtonStyle(kind: .primary))
                        .disabled(model.actionIDs.contains(workload.id))
                    }
                    if workload.canStop {
                        Button("Stop") {
                            Task { await model.stopWorkload(workload) }
                        }
                        .buttonStyle(BVButtonStyle(kind: .ghost))
                        .disabled(model.actionIDs.contains(workload.id))
                        Button("Force stop") {
                            Task { await model.stopWorkload(workload, force: true) }
                        }
                        .buttonStyle(BVButtonStyle(kind: .danger))
                        .disabled(model.actionIDs.contains(workload.id))
                    }
                    Button("Console") { showVNCHint = true }
                        .buttonStyle(BVButtonStyle(kind: .ghost))
                    if let url = webURL {
                        Link("Open in web UI", destination: url)
                            .buttonStyle(BVButtonStyle(kind: .ghost))
                    }
                    if model.actionIDs.contains(workload.id) {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(18)
        .background(BVTheme.bgCard)
        .overlay(
            RoundedRectangle(cornerRadius: BVTheme.radius)
                .stroke(BVTheme.borderGlass, lineWidth: 1)
        )
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
