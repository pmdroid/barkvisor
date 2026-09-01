import SwiftUI

struct WorkloadDetailView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var pendingForceStop = false
    @State private var pendingReset = false
    @State private var pendingBurn = false
    @State private var guest: GuestInfo?
    @State private var networkMode: String?
    @State private var libraryLoad: WorkloadISOLibraryLoad = .pending
    @State private var selectedISOID = ""
    @State private var deviceCaps: SystemCapabilities?
    @State private var hostGPUs: [HostGPUDevice] = []
    @State private var hostUSBs: [HostUSBDevice] = []

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
                if let mac = WorkloadGuestSummary.macLabel(workload: workload, guest: guest) {
                    LabeledContent("MAC", value: mac)
                        .textSelection(.enabled)
                }
                LabeledContent(
                    "Addressing",
                    value: WorkloadGuestSummary.addressingSummary(networkMode: networkMode),
                )
                Text(WorkloadGuestSummary.macGuidance(bridged: networkMode == "bridged"))
                .font(.footnote)
                .foregroundStyle(.secondary)
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
                if codingAgent, model.showsChat {
                    NavigationLink {
                        ChatView()
                    } label: {
                        streamLabel(
                            title: "Chat",
                            subtitle: "Home Ollama grant",
                            systemImage: "bubble.left.and.bubble.right",
                        )
                    }
                }
                streamRow(
                    title: CodingAgentSession.consoleTitle(isSession: codingAgent),
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

            if codingAgent, let session = workload.session {
                Section("Session") {
                    LabeledContent("TTL", value: session.expiryAction == "stop" ? "Stop (keep disk)" : session.expiryAction)
                    if let expires = session.expiresAt {
                        LabeledContent("Expires", value: expires)
                    }
                    if session.warning {
                        Text(CodingAgentSession.warningCopy(remainingSeconds: session.remainingSeconds))
                            .foregroundStyle(.orange)
                    }
                    if let line = session.receiptLine(vmState: workload.state) {
                        LabeledContent("Stopped at", value: line.stoppedAt)
                        Text(line.git)
                            .fontWeight(line.loud ? .bold : .regular)
                            .foregroundStyle(line.loud ? .red : .primary)
                    }
                    if workload.canStart {
                        Button("Resume") {
                            Task { await model.resumeSession(workload, on: device) }
                        }
                        .disabled(busy)
                    }
                    Button("Reset to Library image") { pendingReset = true }
                        .disabled(busy)
                    Button("Burn", role: .destructive) { pendingBurn = true }
                        .disabled(busy)
                }
            }

            isoSection

            if !codingAgent {
                usbSection
            }

            Section("GPU passthrough") {
                if let caps = deviceCaps ?? model.capabilities {
                    LabeledContent(
                        "Status",
                        value: caps.gpuPassthroughSupported ? "Host ready" : "Not available",
                    )
                    Text(caps.gpuPassthroughExplanation)
                        .foregroundStyle(.secondary)
                    Link("IOMMU setup", destination: GPUPassthroughCopy.docsURL)
                    if caps.gpuPassthroughSupported {
                        LabeledContent("Guest Ollama", value: GPUPassthroughCopy.guestOllamaPath)
                    }
                } else {
                    Text(GPUPassthroughCopy.iommuNotReady)
                        .foregroundStyle(.secondary)
                    Link("IOMMU setup", destination: GPUPassthroughCopy.docsURL)
                }
                if hostGPUs.count == 1 {
                    Text(GPUPassthroughCopy.singleDisplayWarning)
                        .fontWeight(.semibold)
                        .foregroundStyle(.red)
                }
                if let attached = workload.gpuDevices, !attached.isEmpty {
                    ForEach(attached) { gpu in
                        LabeledContent(gpu.displayName, value: "IOMMU \(gpu.iommuGroup)")
                        LabeledContent(
                            "Group mates",
                            value: GPUPassthroughCopy.groupMatesLabel(
                                pciAddress: gpu.pciAddress,
                                groupAddresses: gpu.groupAddresses,
                            ),
                        )
                        if workload.canDetachGPU {
                            Button("Detach \(gpu.pciAddress)", role: .destructive) {
                                Task {
                                    await model.detachGPU(gpu.pciAddress, from: workload, on: device)
                                    await refreshGPUs()
                                }
                            }
                            .disabled(busy)
                        } else {
                            Text("Stop the Workload to detach.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if (deviceCaps ?? model.capabilities)?.gpuPassthroughSupported == true {
                    ForEach(hostGPUs.filter { gpu in
                        !(workload.gpuDevices ?? []).contains(where: { $0.pciAddress == gpu.pciAddress })
                    }) { gpu in
                        LabeledContent(gpu.name, value: "IOMMU \(gpu.iommuGroup)")
                        LabeledContent(
                            "Group mates",
                            value: GPUPassthroughCopy.groupMatesLabel(
                                pciAddress: gpu.pciAddress,
                                groupAddresses: gpu.groupAddresses,
                            ),
                        )
                        if let occupancy = gpu.occupancyCopy {
                            Text(occupancy)
                                .foregroundStyle(.secondary)
                        }
                        if workload.canStart {
                            Button("Attach \(gpu.pciAddress)") {
                                Task {
                                    await model.attachGPU(gpu.pciAddress, to: workload, on: device)
                                    await refreshGPUs()
                                }
                            }
                            .disabled(busy || !gpu.canAttach)
                        } else {
                            Text("Stop the Workload to attach.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

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

            Section {
                Toggle(isOn: Binding(
                    get: { workload.startsOnDeviceBoot },
                    set: { enabled in
                        Task { await model.setStartOnBoot(workload, enabled: enabled, on: device) }
                    },
                )) {
                    Text(WorkloadStartOnBoot.label)
                }
                .disabled(busy || !device.isReachable)
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
                VStack(alignment: .leading, spacing: 6) {
                    Text(workload.startOnBootFooter)
                    if workload.canStop || workload.canRestart {
                        Text("Stop and Restart send ACPI. Force Stop does not shut the guest down cleanly.")
                    }
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
            .task(id: deviceID) {
                guard device.isReachable else {
                    deviceCaps = nil
                    hostGPUs = []
                    hostUSBs = []
                    return
                }
                deviceCaps = await model.capabilities(for: device)
                await refreshGPUs()
                await refreshUSBs()
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
            .alert("Reset to Library image?", isPresented: $pendingReset) {
                Button("Reset", role: .destructive) {
                    Task { await model.resetSession(workload, on: device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The boot disk is replaced. Files that were not pushed are lost.")
            }
            .alert("Burn \(workload.name)?", isPresented: $pendingBurn) {
                Button("Burn", role: .destructive) {
                    Task { await model.burnSession(workload, on: device) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Destroys the Workload and unloads the local-model grant.")
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

    private var codingAgent: Bool {
        CodingAgentSession.isSession(workloadClass: workload.workloadClass)
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

    private func refreshGPUs() async {
        hostGPUs = await model.gpuDevices(on: device)
    }

    private func refreshUSBs() async {
        let target = device
        let hostId = target.hostId
        let rows = await model.usbDevices(on: target)
        guard !Task.isCancelled, device.hostId == hostId else { return }
        hostUSBs = rows
    }

    private var usbSection: some View {
        Section("USB") {
            if let attached = workload.usbDevices, !attached.isEmpty {
                ForEach(attached) { usb in
                    LabeledContent(usb.displayName, value: usb.id)
                    if workload.canDetachUSB {
                        Button("Detach \(usb.displayName)", role: .destructive) {
                            Task {
                                await model.detachUSB(usb.id, from: workload, on: device)
                                await refreshUSBs()
                            }
                        }
                        .disabled(busy)
                    } else {
                        Text("Stop the Workload to detach.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if (deviceCaps ?? model.capabilities)?.usbPassthroughSupported == true {
                ForEach(hostUSBs.filter { host in
                    !(workload.usbDevices ?? []).contains(where: { $0.id == host.id })
                }) { usb in
                    LabeledContent(usb.name, value: usb.id)
                    if let occupancy = usb.occupancyCopy {
                        Text(occupancy)
                            .foregroundStyle(.secondary)
                    }
                    if workload.canStart {
                        Button("Attach \(usb.name)") {
                            Task {
                                await model.attachUSB(usb.id, to: workload, on: device)
                                await refreshUSBs()
                            }
                        }
                        .disabled(busy || !usb.canAttach)
                    } else {
                        Text("Stop the Workload to attach.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
