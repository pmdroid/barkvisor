import SwiftUI

struct WorkloadDetailView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var pendingForceStop = false

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    StatusLabel.health(workload.resolvedHealth)
                }
                LabeledContent(Copy.device, value: device.title)
                LabeledContent("Guest", value: guestLine)
            }

            Section {
                streamRow(
                    title: "Console",
                    subtitle: "Serial",
                    systemImage: "apple.terminal",
                    destination: SerialConsoleView(
                        workloadID: workload.id,
                        deviceID: device.hostId,
                        fallbackWorkload: workload,
                        fallbackDevice: device
                    )
                )
                streamRow(
                    title: "Display",
                    subtitle: "VNC",
                    systemImage: "display",
                    destination: DisplayView(
                        workloadID: workload.id,
                        deviceID: device.hostId,
                        fallbackWorkload: workload,
                        fallbackDevice: device
                    )
                )
            }

            if workload.canStart || workload.canStop {
                Section {
                    if workload.canStart {
                        Button("Start") {
                            Task { await model.startWorkload(workload, on: device) }
                        }
                        .disabled(busy)
                    }
                    if workload.canStop {
                        Button("Stop") {
                            Task { await model.stopWorkload(workload, on: device) }
                        }
                        .disabled(busy)
                        Button("Force Stop", role: .destructive) {
                            pendingForceStop = true
                        }
                        .disabled(busy)
                    }
                }
            }
        }
        .platformListStyle()
        .navigationTitle(workload.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Force stop \(workload.name)?", isPresented: $pendingForceStop) {
            Button("Force Stop", role: .destructive) {
                Task { await model.stopWorkload(workload, force: true, on: device) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The guest will not shut down cleanly.")
        }
    }

    private var workload: Workload {
        if let home = model.homeRows.first(where: { $0.workload.id == workloadID && $0.device.hostId == deviceID }) {
            return home.workload
        }
        if model.selectedDevice?.hostId == deviceID, let live = model.workloads.first(where: { $0.id == workloadID }) {
            return live
        }
        return fallbackWorkload
    }

    private var device: HomeDeviceHealthSnapshot {
        model.devices.first(where: { $0.hostId == deviceID }) ?? fallbackDevice
    }

    private var access: WorkloadStreamAccess {
        WorkloadStreamAccess.resolve(isSelfDevice: device.isSelf, state: workload.state)
    }

    private var busy: Bool {
        model.actionIDs.contains("\(device.hostId)/\(workload.id)") || model.actionIDs.contains(workload.id)
    }

    private var guestLine: String {
        let os = workload.vmType.localizedCaseInsensitiveContains("windows") ? "Windows" : "Linux"
        let gb = Double(workload.memoryMB) / 1024
        let memory: String
        if gb >= 1 {
            memory = gb.rounded() == gb
                ? "\(Int(gb)) GB"
                : String(format: "%.1f GB", gb)
        } else {
            memory = "\(workload.memoryMB) MB"
        }
        return "\(os) · \(workload.cpuCount) vCPU · \(memory)"
    }

    @ViewBuilder
    private func streamRow<Destination: View>(
        title: String,
        subtitle: String,
        systemImage: String,
        destination: Destination
    ) -> some View {
        if access.allowsOpen {
            NavigationLink {
                destination
            } label: {
                streamLabel(title: title, subtitle: subtitle, systemImage: systemImage)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                streamLabel(title: title, subtitle: subtitle, systemImage: systemImage)
                    .foregroundStyle(.secondary)
                Text(access.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func streamLabel(title: String, subtitle: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
