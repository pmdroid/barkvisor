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
    @State private var libraryQuery = ""
    @State private var libraryHits: OllamaLibrarySearchResponse?
    @State private var librarySearchGen = 0
    @State private var librarySearching = false
    @State private var libraryError: String?
    @State private var startCandidate: OllamaCatalogModel?
    @State private var startHostId = ""
    @State private var stopCandidate: OllamaCatalogModel?
    @State private var keySheet = false
    @State private var keyHostId = ""
    @State private var keyDraft = ""
    @State private var keySaving = false
    @State private var statsHostId = ""
    @State private var points: [DeviceStatsChartPoint] = []
    @State private var mintedKey: String?
    @State private var mintAttempted = false
    @State private var rechecking = false

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
                    installSection
                }
                .platformListStyle()
            } else {
                List {
                    howToSection
                    liveStatsSection
                    Section("Pull by name") {
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
                    Section("Library search") {
                        TextField("Search the Ollama library", text: $libraryQuery)
                        Button("Search") {
                            Task { await searchLibrary() }
                        }
                        .disabled(OllamaLibrarySearchResponse.query(libraryQuery) == nil || librarySearching)
                        if OllamaLibrarySearchResponse.query(libraryQuery) == nil {
                            Text("Enter a name to search the Ollama library.")
                                .foregroundStyle(.secondary)
                        } else if librarySearching {
                            ProgressView("Searching…")
                        } else if let libraryError {
                            Text(libraryError)
                                .foregroundStyle(.secondary)
                        } else if let hits = libraryHits,
                                  hits.query == OllamaLibrarySearchResponse.query(libraryQuery) {
                            if hits.results.isEmpty {
                                Text("No library matches.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(hits.results) { row in
                                    HStack {
                                        Text(row.name)
                                        Spacer()
                                        Button("Download") {
                                            Task { await pullModel(name: row.pullName) }
                                        }
                                        .disabled(row.pullName.isEmpty || pulling)
                                    }
                                }
                            }
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
                .searchable(text: $nameQuery, prompt: "Filter pulled models")
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

    private var installOses: [String] {
        OllamaInstall.oses(
            installHints: catalog.devices.map(\.installHint),
            platformOs: model.selectedDevice?.platform?.os
                ?? model.devices.first(where: \.isSelf)?.platform?.os,
        )
    }

    private var installHint: String {
        OllamaInstall.catalogHint(devices: catalog.devices, os: installOses.first ?? "macos")
    }

    private var deviceInstallLines: [OllamaDeviceStatus] {
        catalog.devices.filter { !$0.installHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var installSection: some View {
        Section {
            ContentUnavailableView(
                "Ollama is not reachable",
                systemImage: "cube",
            )
            if deviceInstallLines.isEmpty {
                Text(installHint)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(deviceInstallLines) { device in
                    Text("\(device.title) — \(device.installHint)")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(installOses, id: \.self) { os in
                Text(OllamaInstall.osLabel(os))
                    .font(.subheadline.weight(.semibold))
                ForEach(OllamaInstall.steps(os: os)) { step in
                    if let command = step.command {
                        CopyableSnippet(title: step.title, text: command)
                    } else if let href = step.href {
                        CopyableSnippet(title: step.title, text: href)
                        if let url = URL(string: href) {
                            Link(href, destination: url)
                        }
                    } else {
                        Text(step.title)
                    }
                }
            }
            Button("Recheck") {
                guard OllamaInstall.canRecheck(
                    rechecking: rechecking,
                    refreshInFlight: model.ollamaRefreshing,
                ) else { return }
                rechecking = true
                Task {
                    await model.refreshOllamaCatalog()
                    rechecking = false
                }
            }
            .disabled(
                !OllamaInstall.canRecheck(
                    rechecking: rechecking,
                    refreshInFlight: model.ollamaRefreshing,
                ),
            )
        }
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
                    .disabled(
                        model.actionIDs.contains("ollama/\(row.name)")
                            || !row.canStart(selectedHostId: model.selectedDevice?.hostId),
                    )
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
        let scope = model.selectedDevice?.hostId
        if !row.canStart(selectedHostId: scope) {
            model.banner = row.startDisabledReason(selectedHostId: scope)
            return
        }
        if row.startNeedsPicker(selectedHostId: scope) {
            startHostId = row.defaultStartHostId(selectedHostId: scope) ?? ""
            startCandidate = row
            return
        }
        Task { await model.startOllama(row.name, hostId: row.soleStartHostId(selectedHostId: scope)) }
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
            .onChange(of: startHostId) { _, hostId in
                if startPickerDevices(for: row).contains(where: { $0.hostId == hostId && !$0.reachable }) {
                    startHostId = row.defaultStartHostId ?? ""
                }
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
                    .disabled(
                        model.actionIDs.contains("ollama/\(row.name)")
                            || startHostId.isEmpty
                            || !startPickerDevices(for: row).contains { $0.hostId == startHostId && $0.reachable },
                    )
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
    }

    /// Start picker lists Devices that already have the model, not every reachable Device.
    private func startPickerDevices(for row: OllamaCatalogModel) -> [OllamaDeviceStatus] {
        row.startReachableCandidates(selectedHostId: model.selectedDevice?.hostId).map { loc in
            var device = catalog.devices.first { $0.hostId == loc.hostId }
                ?? OllamaDeviceStatus(
                    hostId: loc.hostId,
                    displayName: loc.displayName,
                    installed: true,
                    reachable: loc.reachable,
                    stale: false,
                    installHint: "",
                )
            device.reachable = loc.reachable
            return device
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
                LabeledContent("GPU", value: "unknown")
            } else {
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
                LabeledContent("GPU", value: gpuNow)
            }
        } header: {
            Text("GPU")
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

    private var gpuPoints: [DeviceStatsChartPoint] {
        points.filter { $0.gpuPercent != nil }
    }

    private var gpuNow: String {
        if let gpu = points.reversed().compactMap(\.gpuPercent).first {
            return String(format: "%.0f%%", gpu)
        }
        return "—"
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
            return
        }
        let nextPoints = await DeviceStatsHistory.points(from: model.statsHistory(on: target))
        guard !Task.isCancelled, statsHostId == requestedHost else { return }
        points = nextPoints
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

    private func searchLibrary() async {
        let gen = librarySearchGen + 1
        librarySearchGen = gen
        guard let q = OllamaLibrarySearchResponse.query(libraryQuery) else {
            guard librarySearchGen == gen else { return }
            libraryHits = nil
            libraryError = nil
            return
        }
        librarySearching = true
        libraryError = nil
        defer {
            if librarySearchGen == gen { librarySearching = false }
        }
        do {
            let data = try await model.searchOllamaLibrary(q)
            guard librarySearchGen == gen else { return }
            guard let hits = OllamaLibrarySearchResponse.accept(data, currentQuery: libraryQuery)
            else { return }
            libraryHits = hits
        } catch {
            guard librarySearchGen == gen else { return }
            libraryHits = nil
            libraryError = error.localizedDescription
        }
    }

    private func pullModel(name requested: String? = nil) async {
        let name = (requested ?? pullName).trimmingCharacters(in: .whitespacesAndNewlines)
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
                        if pullName.trimmingCharacters(in: .whitespacesAndNewlines) == name {
                            pullName = ""
                        }
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
                Text(device.reachable ? device.title : "\(device.title) (unreachable)")
                    .tag(device.hostId)
                    .disabled(!device.reachable)
            }
        }
    }
}
