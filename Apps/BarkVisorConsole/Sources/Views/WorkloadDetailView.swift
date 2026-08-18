import SwiftUI

struct WorkloadDetailView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var pendingForceStop = false
    @State private var guest: GuestInfo?

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    StatusLabel.health(workload.resolvedHealth)
                }
                LabeledContent("State", value: workload.state.replacingOccurrences(of: "_", with: " ").capitalized)
                LabeledContent(Copy.device, value: device.title)
                LabeledContent("Guest OS", value: WorkloadGuestSummary.osLabel(workload: workload, guest: guest))
                if let ip = WorkloadGuestSummary.ipLabel(guest: guest) {
                    LabeledContent("IP", value: ip)
                        .textSelection(.enabled)
                }
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
                } footer: {
                    Text("Stop sends ACPI. Force Stop does not shut the guest down cleanly.")
                }
            }
        }
        .platformListStyle()
        .navigationTitle(workload.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(deviceID)/\(workloadID)/\(workload.state)") {
            while !Task.isCancelled {
                if !device.isReachable { return }
                guest = await model.guestInfo(for: workload.id, on: device)
                if !GuestInfoRefresh.shouldRetry(
                    guest: guest,
                    running: workload.isRunning,
                    reachable: device.isReachable
                ) {
                    return
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
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
        let key = WorkloadActionKey.id(hostID: device.hostId, workloadID: workload.id)
        return model.actionIDs.contains(key) || model.actionIDs.contains(workload.id)
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

extension WorkloadDetailView {
    init(row: HomeWorkloadRow) {
        self.init(
            workloadID: row.workload.id,
            deviceID: row.device.hostId,
            fallbackWorkload: row.workload,
            fallbackDevice: row.device
        )
    }
}
