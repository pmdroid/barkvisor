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
                ShareLink(
                    item: OllamaPsShareFile(models: catalog.models),
                    preview: SharePreview(OllamaPsExport.filename),
                ) {
                    Label("Export JSON", systemImage: "square.and.arrow.up")
                }
                .disabled(catalog.models.isEmpty)
            }
        }
        .refreshable { await model.refreshOllama() }
        .task {
            await model.refreshOllama()
            await mintHowToKeyIfNeeded()
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
        startHostId = ""
        startCandidate = row
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
                OllamaReachableDevicePicker(hostId: $startHostId, devices: reachableDevices)
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
                    .disabled(model.actionIDs.contains("ollama/\(row.name)"))
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium])
        #endif
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
