import Charts
import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    var deviceID: String
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var points: [DeviceStatsChartPoint] = []
    @State private var deviceAbout: SystemAbout?
    @State private var deviceCaps: SystemCapabilities?
    @State private var hostGPUs: [HostGPUDevice] = []
    @State private var showRename = false
    @State private var nameDraft = ""
    @State private var renaming = false

    var body: some View {
        List {
            Section {
                LabeledContent("Platform", value: device.platformLabel)
                LabeledContent("Status") {
                    StatusLabel.reachability(device)
                }
                LabeledContent(Copy.workloads, value: device.workloadLine)
                if let resources = device.resourcesLine {
                    LabeledContent("Resources", value: resources)
                }
            }

            if device.isSelf || device.isReachable {
                DiskDirectorySection(device: device)
                    .id(device.hostId)
            }

            #if os(iOS)
                Section {
                    NavigationLink {
                        DisksView()
                            .navigationTitle(AppRoute.disks.title)
                    } label: {
                        Label(AppRoute.disks.title, systemImage: AppRoute.disks.symbol)
                    }
                    NavigationLink {
                        NetworksView()
                            .navigationTitle(AppRoute.networks.title)
                    } label: {
                        Label(AppRoute.networks.title, systemImage: AppRoute.networks.symbol)
                    }
                    NavigationLink {
                        LogsView()
                            .navigationTitle(AppRoute.logs.title)
                    } label: {
                        Label(AppRoute.logs.title, systemImage: AppRoute.logs.symbol)
                    }
                } footer: {
                    Text("Read-only. Create and the depot path stay in the web UI.")
                }
            #endif

            if DeviceStatsHistory.shouldFetch(device) {
                Section("About") {
                    if let deviceAbout {
                        LabeledContent("Device version", value: deviceAbout.version)
                        LabeledContent("Platform", value: "\(deviceAbout.platform) · \(deviceAbout.hostArch)")
                        LabeledContent("Accelerator", value: deviceAbout.accelerator)
                        LabeledContent("Uptime", value: "\(deviceAbout.processUptimeSeconds)s")
                    } else {
                        Text("Could not load this \(Copy.device.lowercased()) version.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("GPU passthrough") {
                    if let caps = deviceCaps {
                        LabeledContent(
                            "GPU passthrough",
                            value: caps.gpuPassthroughSupported ? "Host ready" : "Not available",
                        )
                        Text(caps.gpuPassthroughExplanation)
                            .foregroundStyle(.secondary)
                        Link("IOMMU setup", destination: GPUPassthroughCopy.docsURL)
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
                    ForEach(hostGPUs) { gpu in
                        LabeledContent(gpu.name, value: "\(gpu.pciAddress) · IOMMU \(gpu.iommuGroup)")
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
                    }
                }

                Section("Doctor") {
                    if deviceCaps == nil {
                        Text(DeviceDoctor.loadFailedCopy)
                            .foregroundStyle(.secondary)
                    } else if doctorRows.isEmpty {
                        Text(DeviceDoctor.emptyCopy)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(doctorRows, id: \.code) { detail in
                            LabeledContent(
                                DeviceDoctor.title(for: detail.code),
                                value: DeviceDoctor.statusLabel(supported: detail.supported),
                            )
                            if let note = DeviceDoctor.note(for: detail) {
                                Text(note)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            if !DeviceStatsHistory.shouldFetch(device) {
                Section {
                    Text(DeviceStatsHistory.unavailableCopy(device))
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("CPU") {
                    if points.count > 1 {
                        Chart(points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("CPU", point.cpuPercent),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("CPU", point.cpuPercent),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.accentColor.opacity(0.12))
                        }
                        .chartYScale(domain: 0 ... 100)
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("CPU history")
                    }
                    LabeledContent("Now", value: cpuNow)
                }

                Section("Memory") {
                    if points.count > 1 {
                        Chart(points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Memory", point.memoryUsedGB),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.green.opacity(0.8))
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("Memory", point.memoryUsedGB),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.green.opacity(0.12))
                        }
                        .chartYScale(domain: 0 ... memoryCeiling)
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("Memory history")
                    }
                    LabeledContent("Now", value: memoryNow)
                }

                Section("GPU") {
                    if gpuPoints.count > 1 {
                        Chart(gpuPoints) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("GPU", point.gpuPercent ?? 0),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.purple.opacity(0.8))
                            AreaMark(
                                x: .value("Time", point.date),
                                y: .value("GPU", point.gpuPercent ?? 0),
                            )
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Color.purple.opacity(0.12))
                        }
                        .chartYScale(domain: 0 ... 100)
                        .chartXAxis(.hidden)
                        .frame(height: 140)
                        .accessibilityLabel("GPU history")
                    }
                    LabeledContent("Now", value: gpuNow)
                }
            }
        }
        .platformListStyle()
        .navigationTitle(device.title)
        .toolbar {
            if DeviceRename.canRename(device) {
                Button("Rename") {
                    nameDraft = device.title
                    showRename = true
                }
                .disabled(renaming)
            }
        }
        .alert("Device name", isPresented: $showRename) {
            TextField("Device name", text: $nameDraft)
            Button("Save") {
                Task { await saveRename() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How this Device appears in the Home.")
        }
        .onChange(of: deviceID) { _, _ in
            model.clearDiskSettings(for: device)
        }
        .task(id: "\(deviceID)-\(device.role)-\(device.reachability)") {
            await model.select(device)
            await loadHistory()
            await loadAbout()
        }
        .refreshable {
            await loadHistory()
            await loadAbout()
        }
    }

    private var device: HomeDeviceHealthSnapshot {
        model.devices.first(where: { $0.hostId == deviceID }) ?? fallbackDevice
    }

    private var doctorRows: [CapabilityDetail] {
        DeviceDoctor.rows(from: deviceCaps)
    }

    private var cpuNow: String {
        if let last = points.last {
            return String(format: "%.0f%%", last.cpuPercent)
        }
        if let cpu = device.resources?.cpuLoadPercent {
            return String(format: "%.0f%%", cpu)
        }
        return "—"
    }

    private var memoryNow: String {
        if let last = points.last {
            return String(format: "%.1f / %.0f GB", last.memoryUsedGB, last.memoryTotalGB)
        }
        if let used = device.resources?.memoryUsedMB, let total = device.resources?.memoryTotalMB {
            return String(format: "%.1f / %.0f GB", Double(used) / 1_024, Double(total) / 1_024)
        }
        return "—"
    }

    private var memoryCeiling: Double {
        max(points.last?.memoryTotalGB ?? 1, 1)
    }

    private var gpuPoints: [DeviceStatsChartPoint] {
        points.filter { $0.gpuPercent != nil }
    }

    private var gpuNow: String {
        if let gpu = points.reversed().compactMap(\.gpuPercent).first {
            return String(format: "%.0f%%", gpu)
        }
        return "—"
    }

    private func loadHistory() async {
        let target = device
        guard DeviceStatsHistory.shouldFetch(target) else {
            guard !Task.isCancelled else { return }
            points = []
            return
        }
        let next = await DeviceStatsHistory.points(from: model.statsHistory(on: target))
        guard !Task.isCancelled else { return }
        points = next
    }

    private func loadAbout() async {
        let target = device
        guard DeviceStatsHistory.shouldFetch(target) else {
            guard !Task.isCancelled else { return }
            deviceAbout = nil
            deviceCaps = nil
            hostGPUs = []
            return
        }
        let about = await model.about(on: target)
        guard !Task.isCancelled else { return }
        let caps = await model.capabilities(for: target)
        guard !Task.isCancelled else { return }
        let gpus = await model.gpuDevices(on: target)
        guard !Task.isCancelled else { return }
        deviceAbout = about
        deviceCaps = caps
        hostGPUs = gpus
    }

    private func saveRename() async {
        guard DeviceRename.canRename(device), let name = DeviceRename.parse(nameDraft) else { return }
        renaming = true
        defer { renaming = false }
        _ = await model.saveDeviceName(name, on: device)
    }
}

private struct DiskDirectorySection: View {
    @Environment(AppModel.self) private var model
    var device: HomeDeviceHealthSnapshot
    @State private var draft = ""
    @State private var saving = false
    #if os(iOS)
        @State private var showFolderPicker = false
    #endif

    var body: some View {
        Section {
            Text("New disks on this \(Copy.device) go here unless Create Disk picks another folder.")
                .foregroundStyle(.secondary)
            TextField("Default VM disk directory", text: $draft)
                .disabled(saving || !canEdit)
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            #endif
            #if os(iOS)
            Button("Browse") {
                showFolderPicker = true
            }
            .disabled(saving || !canEdit)
            #endif
            if let settings = model.diskSettings(for: device) {
                Text(settings.isDefault ? "Using the default path on this Device." : "Using a custom disk directory.")
                    .foregroundStyle(.secondary)
            }
            Button("Save") {
                Task {
                    let host = device.hostId
                    let directory = draft
                    guard !directory.isEmpty else { return }
                    saving = true
                    defer { if device.hostId == host { saving = false } }
                    _ = await model.saveDiskSettings(directory, on: device)
                    guard device.hostId == host else { return }
                    if let settings = model.diskSettings(for: device) { draft = settings.diskDirectory }
                }
            }
            .disabled(saving || !canEdit || draft.isEmpty)
            Button("Reset to default") {
                Task {
                    let host = device.hostId
                    saving = true
                    defer { if device.hostId == host { saving = false } }
                    _ = await model.saveDiskSettings("", on: device)
                    guard device.hostId == host else { return }
                    if let settings = model.diskSettings(for: device) { draft = settings.diskDirectory }
                }
            }
            .disabled(saving || !canEdit || model.diskSettings(for: device)?.isDefault != false)
        } header: {
            Text("Disk directory")
        }
        .task(id: "\(device.hostId)-\(device.isReachable)") {
            model.clearDiskSettings(for: device)
            await model.refreshDiskSettings(on: device)
            if !draft.isEmpty, draft != (model.diskSettings(for: device)?.diskDirectory ?? "") { return }
            draft = model.diskSettings(for: device)?.diskDirectory ?? ""
        }
        #if os(iOS)
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView(device: device) { path in
                    draft = path
                }
            }
        #endif
    }

    private var canEdit: Bool {
        device.isSelf || device.isReachable
    }
}
