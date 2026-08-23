import SwiftUI

struct WorkloadDetailView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var pendingForceStop = false
    @State private var guest: GuestInfo?
    @State private var networkMode: String?
    @State private var libraryLoad: WorkloadISOLibraryLoad = .pending
    @State private var selectedISOID = ""

    var body: some View {
        List {
            Section {
                LabeledContent("Status") {
                    StatusLabel.health(workload.resolvedHealth)
                }
                LabeledContent("State", value: workload.state.replacingOccurrences(of: "_", with: " ").capitalized)
                LabeledContent(Copy.device, value: device.title)
                LabeledContent("Class", value: workload.grantCopy)
                LabeledContent("Guest OS", value: WorkloadGuestSummary.osLabel(workload: workload, guest: guest))
                if let ip = WorkloadGuestSummary.ipLabel(guest: guest) {
                    LabeledContent("IP", value: ip)
                        .textSelection(.enabled)
                }
            }

            if guest?.available == true, device.isReachable {
                Section("Listening ports") {
                    if let ports = guest?.listeningPorts {
                        let visible = ports.filter(\.isPublished)
                        if visible.isEmpty {
                            Text("None")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visible, id: \.self) { port in
                                LabeledContent(port.displayLabel) {
                                    if port.isInternal {
                                        Text("Internal")
                                    } else if let url = port.openURL(
                                        guestIPs: guest?.ipAddresses ?? [],
                                        access: listeningAccess,
                                    ) {
                                        Link(url.absoluteString, destination: url)
                                    } else {
                                        Text("\(port.address):\(port.port)")
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    } else {
                        Text("Unavailable")
                            .foregroundStyle(.secondary)
                    }
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
                        fallbackDevice: device,
                    ),
                )
                streamRow(
                    title: "Display",
                    subtitle: "VNC",
                    systemImage: "display",
                    destination: DisplayView(
                        workloadID: workload.id,
                        deviceID: device.hostId,
                        fallbackWorkload: workload,
                        fallbackDevice: device,
                    ),
                )
            }

            isoSection

            if let url = model.connectedURL {
                Section {
                    Link(
                        CreateWorkload.webEditCopy,
                        destination: WorkloadWebLink.page(
                            base: url,
                            workloadID: workload.id,
                            device: device,
                        ),
                    )
                }
            }

            if workload.canStart || workload.canStop || workload.canRestart {
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
                    if workload.canRestart {
                        Button("Restart") {
                            Task {
                                guest = nil
                                await model.restartWorkload(workload, on: device)
                                guest = await model.guestInfo(for: workload.id, on: device)
                            }
                        }
                        .disabled(!WorkloadRestart.isEnabled(device: device, busy: busy))
                    }
                } footer: {
                    Text("Stop and Restart send ACPI. Force Stop does not shut the guest down cleanly.")
                }
            }
        }
        .platformListStyle()
        .navigationTitle(workload.name)
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
            .task(id: "\(deviceID)/\(workload.networkId ?? "")") {
                networkMode = await model.networkMode(for: workload.networkId, on: device)
            }
            .task(id: WorkloadISOMedia.libraryTaskID(deviceID: deviceID, reachable: device.isReachable)) {
                await loadLibrary()
            }
            .task(id: GuestInfoRefresh.taskID(
                deviceID: deviceID,
                workloadID: workloadID,
                state: workload.state,
                reachable: device.isReachable,
                busy: busy,
            )) {
                while !Task.isCancelled {
                    if !device.isReachable || busy { return }
                    guest = await model.guestInfo(for: workload.id, on: device)
                    guard let interval = GuestInfoRefresh.pollIntervalSeconds(
                        guest: guest,
                        running: workload.isRunning,
                        reachable: device.isReachable,
                    ) else { return }
                    try? await Task.sleep(for: .seconds(interval))
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
        WorkloadStreamAccess.resolve(device: device, state: workload.state)
    }

    private var listeningAccess: GuestListeningPortAccess {
        GuestListeningPortAccess(
            isMember: !device.isSelf,
            guestIpsReachable: networkMode == "bridged",
            portForwards: workload.portForwards ?? [],
        )
    }

    private var busy: Bool {
        let key = WorkloadActionKey.id(hostID: device.hostId, workloadID: workload.id)
        return model.actionIDs.contains(key) || model.actionIDs.contains(workload.id)
    }

    private var deviceLibrary: [LibraryImage] {
        if model.selectedDevice?.hostId == deviceID, !model.images.isEmpty {
            return model.images
        }
        return libraryLoad.images
    }

    private var libraryKnown: Bool {
        if model.selectedDevice?.hostId == deviceID, !model.images.isEmpty {
            return true
        }
        return libraryLoad.isKnown
    }

    private var isoAccess: WorkloadISOAccess {
        WorkloadISOAccess.resolve(reachable: device.isReachable, busy: busy)
    }

    private var isoMedia: [WorkloadISOMediaItem] {
        WorkloadISOMedia.attached(
            ids: workload.attachedISOIds,
            library: deviceLibrary,
            libraryKnown: libraryKnown,
        )
    }

    private var attachableISOs: [LibraryImage] {
        WorkloadISOMedia.attachable(library: deviceLibrary, attachedIDs: workload.attachedISOIds)
    }

    private var isoSection: some View {
        Section {
            if isoMedia.isEmpty {
                Text("None attached")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(isoMedia) { item in
                    LabeledContent {
                        if isoAccess.allowsChange {
                            Button("Eject") {
                                Task { await model.ejectISO(item.id, from: workload, on: device) }
                            }
                            .disabled(busy)
                        }
                    } label: {
                        Text(item.displayName)
                        if item.isMissing {
                            Text("Missing from this Device Library")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            if isoAccess.allowsChange {
                if libraryKnown {
                    if attachableISOs.isEmpty {
                        Text("No ready ISOs in this Device Library")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Attach", selection: $selectedISOID) {
                            Text("Select ISO").tag("")
                            ForEach(attachableISOs) { image in
                                Text(image.name).tag(image.id)
                            }
                        }
                        Button("Attach") {
                            let isoID = selectedISOID
                            guard !isoID.isEmpty else { return }
                            Task {
                                await model.attachISO(isoID, to: workload, on: device)
                                selectedISOID = ""
                            }
                        }
                        .disabled(selectedISOID.isEmpty || busy)
                    }
                } else if libraryLoad.showsSpinner {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Retry") {
                        Task { await loadLibrary() }
                    }
                    .disabled(busy)
                }
            }
        } header: {
            Text("ISO")
        } footer: {
            isoFooter
        }
    }

    private func loadLibrary() async {
        guard device.isReachable else { return }
        if !libraryLoad.isKnown { libraryLoad = .pending }
        libraryLoad = await libraryLoad.applying(model.libraryImages(on: device))
    }

    @ViewBuilder
    private var isoFooter: some View {
        if let reason = isoAccess.reason {
            Text(reason)
        } else if workload.pendingChanges == true {
            Text("Restart the Workload to apply media changes.")
        }
    }

    @ViewBuilder
    private func streamRow(
        title: String,
        subtitle: String,
        systemImage: String,
        destination: some View,
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
            fallbackDevice: row.device,
        )
    }
}
