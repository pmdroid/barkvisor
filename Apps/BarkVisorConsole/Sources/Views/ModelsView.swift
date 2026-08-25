import Charts
import SwiftUI

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var pullName = ""
    @State private var pullHostId = ""
    @State private var pulling = false
    @State private var cancelling = false
    @State private var pullTask: OllamaTaskAccepted?
    @State private var pullEvent: OllamaTaskEvent?
    @State private var nameQuery = ""
    @State private var startCandidate: OllamaCatalogModel?
    @State private var startHostId = ""
    @State private var stopCandidate: OllamaCatalogModel?
    @State private var keySheet = false
    @State private var keyHostId = ""
    @State private var keyDraft = ""
    @State private var keySaving = false
    @State private var statsHostId = ""
    @State private var points: [DeviceStatsChartPoint] = []
    @State private var hostGPUs: [HostGPUDevice] = []
    @State private var gpusLoaded = false
    @State private var mintedKey: String?
    @State private var mintAttempted = false

    var body: some View {
        Group {
            if !model.ollamaLoaded {
                List {
                    howToSection
                    Section {
                        ProgressView("Loading Ollama…")
                    }
                }
                .platformListStyle()
            } else if !catalog.anyReachable {
                List {
                    howToSection
                    Section {
                        ContentUnavailableView(
                            "Ollama is not reachable",
                            systemImage: "cube",
                            description: Text(catalog.devices.first?.installHint ?? "Install Ollama on a Device."),
                        )
                    }
                }
                .platformListStyle()
            } else {
                List {
                    howToSection
                    liveStatsSection
                    Section("Pull a model") {
                        TextField("llama3", text: $pullName)
                        OllamaReachableDevicePicker(hostId: $pullHostId, devices: reachableDevices)
                        if pulling {
                            if let fraction = pullFraction {
                                ProgressView(value: fraction) { Text(pullLabel) }
                            } else {
                                ProgressView(pullLabel)
                            }
                            Button("Cancel", role: .cancel) {
                                Task { await cancelPull() }
                            }
                            .disabled(cancelling)
                        } else {
                            Button("Pull") {
                                Task { await pullModel() }
                            }
                            .disabled(pullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    Section("Models") {
                        if catalog.models.isEmpty {
                            Text("Pull a model to use chat completions through BarkVisor.")
                                .foregroundStyle(.secondary)
                        } else if visibleModels.isEmpty {
                            Text("No matching models.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(visibleModels) { row in
                                modelRow(row)
                            }
                        }
                    }
                    if model.ollamaSettings != nil {
                        keySection
                    }
                }
                .platformListStyle()
                .searchable(text: $nameQuery, prompt: "Search models")
            }
        }
        .navigationTitle("Ollama")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareLink(
                        item: OllamaPsShareFile(models: catalog.models),
                        preview: SharePreview(OllamaPsExport.filename),
                    ) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                    .disabled(catalog.models.isEmpty)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .refreshable {
            await model.refreshOllama()
            await loadLiveStats()
        }
        .task {
            await model.refreshOllama()
            await mintHowToKeyIfNeeded()
            syncStatsHost()
            await loadLiveStats()
        }
        .task(id: "\(statsHostId)-\(fetchLiveStats)") {
            await loadLiveStats()
        }
        .sheet(item: $startCandidate, onDismiss: { startHostId = "" }) { row in
            startSheet(row)
        }
        .sheet(isPresented: $keySheet, onDismiss: { keyDraft = "" }) {
            keyEditor
        }
        .confirmationDialog(
            "Stop model",
            isPresented: Binding(
                get: { stopCandidate != nil },
                set: { if !$0 { stopCandidate = nil } },
            ),
            titleVisibility: .visible,
            presenting: stopCandidate,
        ) { row in
            Button("Stop", role: .destructive) {
                Task { await stopLive(row.name) }
                stopCandidate = nil
            }
            Button("Cancel", role: .cancel) { stopCandidate = nil }
        } message: { row in
            Text("Stop \(row.name) on the \(Copy.device) that is running it?")
        }
    }

    private var howTo: InferenceAPIHowTo.Snippets {
        let device = model.selectedDevice
        let isMember = device?.isSelf == false
        return InferenceAPIHowTo.snippets(
            role: isMember ? .member : .thisDevice,
            origin: model.connectedURL,
            memberHost: isMember ? device?.agentHost : nil,
            grantPlaintext: mintedKey,
            advertiseHost: model.remoteAccess?.advertiseUrl,
            tailnetHost: InferenceAPIHowTo.tailnetListenHost(model.remoteAccess?.tailscale),
        )
    }

    private var howToSection: some View {
        Section("Use this API") {
            Text(
                "OpenAI-compatible completions on this \(Copy.home): \(howTo.lanCompletionsURL). Send Authorization: Bearer with an inference key. That is not Device :11434.",
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            CopyableSnippet(title: "curl", text: howTo.curl)
            CopyableSnippet(title: "Environment", text: howTo.env)
            if let mintedKey {
                CopyableSnippet(title: "API key (shown once)", text: mintedKey)
            }
            Text(
                "From inside a Workload, Device Ollama is \(howTo.cageBaseURL) (PAS-268 guestfwd). \(howTo.cageDnsLine)",
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            CopyableSnippet(title: "Cage environment", text: howTo.cageEnv)
        }
    }

    private func mintHowToKeyIfNeeded() async {
        guard !mintAttempted else { return }
        mintAttempted = true
        guard let client = model.client else {
            model.banner = InferenceHowToMint.bannerMessage(from: APIError.unauthorized)
            return
        }
        do {
            let keys = try await client.listAPIKeys()
            guard InferenceHowToMint.needsMint(keys: keys) else { return }
            let body = InferenceHowToMint.createBody()
            let created = try await client.createAPIKey(
                name: body.name,
                expiresIn: body.expiresIn,
                kind: body.kind,
            )
            mintedKey = created.key
        } catch {
            model.banner = InferenceHowToMint.bannerMessage(from: error)
        }
    }

    private var catalog: OllamaHomeCatalog {
        model.ollamaCatalog ?? OllamaHomeCatalog(
            anyReachable: false,
            anyInstalled: false,
            models: [],
            devices: [],
        )
    }

    private var reachableDevices: [OllamaDeviceStatus] {
        catalog.devices.filter(\.reachable)
    }

    private var visibleModels: [OllamaCatalogModel] {
        catalog.models.filter { $0.matchesName(nameQuery) }
    }

    private func modelRow(_ row: OllamaCatalogModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.name).fontWeight(.medium)
                Text(row.locationLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(row.running ? "Running" : "Pulled")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    (row.running ? Color.green : Color.secondary).opacity(0.18),
                    in: Capsule(),
                )
                .foregroundStyle(row.running ? Color.green : .secondary)
            if row.running {
                Button("Stop") { stopCandidate = row }
                    .disabled(model.actionIDs.contains("ollama/\(row.name)"))
            } else {
                Button("Start") { beginStart(row) }
                    .disabled(model.actionIDs.contains("ollama/\(row.name)"))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if row.running {
                Button("Stop", role: .destructive) { stopCandidate = row }
            } else {
                Button("Start") { beginStart(row) }
                    .tint(.green)
            }
        }
        .contextMenu {
            if row.running {
                Button("Stop", role: .destructive) { stopCandidate = row }
            } else {
                Button("Start") { beginStart(row) }
            }
        }
    }

    private var keySection: some View {
        Section {
            Button("Set API key") {
                keyHostId = reachableDevices.first?.hostId ?? ""
                keyDraft = ""
                keySheet = true
            }
            .disabled(reachableDevices.isEmpty)
            Text(keyStatusLine)
                .foregroundStyle(.secondary)
        } header: {
            Text("Ollama API key")
        } footer: {
            Text("Home holds upstream keys per \(Copy.device).")
        }
    }

    private var keyStatusLine: String {
        let hostId = keyHostId.isEmpty ? reachableDevices.first?.hostId : keyHostId
        if let hostId, model.ollamaSettings?.host(hostId)?.hasApiKey == true {
            return "A key is stored for this \(Copy.device)."
        }
        return "No upstream key stored for this \(Copy.device)."
    }

    private var keyEditor: some View {
        NavigationStack {
            Form {
                OllamaReachableDevicePicker(
                    hostId: $keyHostId,
                    devices: reachableDevices,
                    allowAny: false,
                )
                SecureField("OLLAMA_API_KEY", text: $keyDraft)
                Text("Home holds upstream keys per \(Copy.device).")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Ollama API key")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { keySheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveKey() }
                    }
                    .disabled(OllamaSettingsUpdate.saveKey(hostId: keyHostId, draft: keyDraft) == nil || keySaving)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    private func saveKey() async {
        guard let body = OllamaSettingsUpdate.saveKey(hostId: keyHostId, draft: keyDraft) else { return }
        keySaving = true
        defer { keySaving = false }
        let saved = await model.saveOllamaSettings(body)
        if saved {
            keyDraft = ""
            keySheet = false
        }
    }

    private func beginStart(_ row: OllamaCatalogModel) {
        if row.startNeedsPicker {
            startHostId = row.startLocations.first?.hostId ?? ""
            startCandidate = row
            return
        }
        Task { await model.startOllama(row.name, hostId: row.soleStartHostId) }
    }

    private func stopLive(_ name: String) async {
        guard let hostId = OllamaCatalogModel.runningHostId(name: name, in: catalog.models) else {
            model.banner = "Ollama is not running \(name)"
            return
        }
        await model.stopOllama(name, hostId: hostId)
    }

    private func startSheet(_ row: OllamaCatalogModel) -> some View {
        NavigationStack {
            Form {
                OllamaReachableDevicePicker(
                    hostId: $startHostId,
                    devices: startPickerDevices(for: row),
                    allowAny: false,
                )
            }
            .navigationTitle("Start \(row.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { startCandidate = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start") {
                        Task {
                            await model.startOllama(row.name, hostId: startHostId.isEmpty ? nil : startHostId)
                            startCandidate = nil
                        }
                    }
                    .disabled(model.actionIDs.contains("ollama/\(row.name)") || startHostId.isEmpty)
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    /// Start picker lists Devices that already have the model, not every reachable Device.
    private func startPickerDevices(for row: OllamaCatalogModel) -> [OllamaDeviceStatus] {
        row.startLocations.map { loc in
            catalog.devices.first { $0.hostId == loc.hostId }
                ?? OllamaDeviceStatus(
                    hostId: loc.hostId,
                    displayName: loc.displayName,
                    installed: true,
                    reachable: loc.reachable,
                    stale: false,
                    installHint: "",
                )
        }
    }

    @ViewBuilder
    private var liveStatsSection: some View {
        Section {
            Picker(Copy.device, selection: $statsHostId) {
                ForEach(statsPickerDevices) { device in
                    Text(device.reachable ? device.title : "\(device.title) (unreachable)").tag(device.hostId)
                }
            }
            if !fetchLiveStats {
                Text(OllamaDeviceStats.unreachableCopy)
                    .foregroundStyle(.secondary)
                LabeledContent("CPU", value: "unknown")
                LabeledContent("Memory", value: "unknown")
                LabeledContent("GPU", value: "unknown")
            } else {
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
                LabeledContent("CPU", value: cpuNow)
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
                LabeledContent("Memory", value: memoryNow)
            }
        } header: {
            Text("Device stats")
        }

        if fetchLiveStats {
            Section("GPU") {
                if gpusLoaded, hostGPUs.isEmpty {
                    Text(OllamaDeviceStats.gpuEmptyCopy)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hostGPUs) { gpu in
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(OllamaDeviceStats.occupancyLines(gpu), id: \.self) { line in
                                Text(line)
                                    .foregroundStyle(line == gpu.name ? .primary : .secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var statsPickerDevices: [OllamaDeviceStatus] {
        catalog.devices.filter { $0.reachable || $0.hostId == statsHostId }
    }

    private var selectedCatalogDevice: OllamaDeviceStatus? {
        catalog.devices.first { $0.hostId == statsHostId }
    }

    private var statsHealth: HomeDeviceHealthSnapshot? {
        OllamaDeviceStats.healthTarget(
            hostId: statsHostId,
            catalog: catalog.devices,
            devices: model.devices,
        )
    }

    private var fetchLiveStats: Bool {
        OllamaDeviceStats.shouldFetch(catalogDevice: selectedCatalogDevice, health: statsHealth)
    }

    private var cpuNow: String {
        if let last = points.last {
            return String(format: "%.0f%%", last.cpuPercent)
        }
        if let cpu = statsHealth?.resources?.cpuLoadPercent {
            return String(format: "%.0f%%", cpu)
        }
        return "—"
    }

    private var memoryNow: String {
        if let last = points.last {
            return String(format: "%.1f / %.0f GB", last.memoryUsedGB, last.memoryTotalGB)
        }
        if let used = statsHealth?.resources?.memoryUsedMB, let total = statsHealth?.resources?.memoryTotalMB {
            return String(format: "%.1f / %.0f GB", Double(used) / 1_024, Double(total) / 1_024)
        }
        return "—"
    }

    private var memoryCeiling: Double {
        max(points.last?.memoryTotalGB ?? 1, 1)
    }

    private func syncStatsHost() {
        if statsHostId.isEmpty || !catalog.devices.contains(where: { $0.hostId == statsHostId }) {
            statsHostId = OllamaDeviceStats.defaultHostId(models: catalog.models, devices: catalog.devices)
        }
    }

    private func loadLiveStats() async {
        syncStatsHost()
        let requestedHost = statsHostId
        guard fetchLiveStats, let target = statsHealth else {
            guard !Task.isCancelled, statsHostId == requestedHost else { return }
            points = []
            hostGPUs = []
            gpusLoaded = true
            return
        }
        gpusLoaded = false
        async let history = DeviceStatsHistory.points(from: model.statsHistory(on: target))
        async let gpus = model.gpuDevices(on: target)
        let nextPoints = await history
        let nextGpus = await gpus
        guard !Task.isCancelled, statsHostId == requestedHost else { return }
        points = nextPoints
        hostGPUs = nextGpus
        gpusLoaded = true
    }

    private var pullFraction: Double? {
        guard let percent = pullEvent?.percent else { return nil }
        return Double(percent) / 100
    }

    private var pullLabel: String {
        if let percent = pullEvent?.percent {
            return "Pulling \(percent)%"
        }
        return "Pulling…"
    }

    private func pullModel() async {
        let name = pullName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        pulling = true
        defer {
            pulling = false
            pullTask = nil
        }
        do {
            let task = try await model.pullOllama(name, hostId: pullHostId.isEmpty ? nil : pullHostId)
            pullTask = task
            while !Task.isCancelled {
                let event = try await model.ollamaTask(task)
                pullEvent = event
                if event.isTerminal {
                    if event.status == "completed" {
                        pullName = ""
                        await model.refreshOllama()
                    } else if event.status == "cancelled" {
                        model.banner = "Ollama pull cancelled"
                    } else {
                        model.banner = event.error ?? "Ollama could not pull \(name)"
                    }
                    return
                }
                try await Task.sleep(for: .seconds(1))
            }
        } catch {
            model.present(error)
        }
    }

    private func cancelPull() async {
        guard let task = pullTask else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            try await model.cancelOllamaPull(task)
            model.banner = "Ollama pull cancelled"
        } catch {
            model.present(error)
        }
    }
}

private struct OllamaReachableDevicePicker: View {
    @Binding var hostId: String
    var devices: [OllamaDeviceStatus]
    var allowAny: Bool = true

    var body: some View {
        Picker(Copy.device, selection: $hostId) {
            if allowAny {
                Text("Any reachable \(Copy.device)").tag("")
            }
            ForEach(devices) { device in
                Text(device.title).tag(device.hostId)
            }
        }
    }
}
