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
            } else if OllamaInstall.shouldShowInstall(
                loaded: model.ollamaLoaded,
                anyReachable: catalog.anyReachable,
                devices: catalog.devices,
            ) {
                List {
                    howToSection
                    installSection
                }
                .platformListStyle()
            } else {
                List {
                    howToSection
                    Section("Pull by name") {
                        TextField("llama3", text: $pullName)
                        OllamaReachableDevicePicker(
                            hostId: $pullHostId,
                            devices: reachableDevices,
                            allowAny: false,
                        )
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
                            .disabled(
                                pullName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || pullHostId.isEmpty
                                    || reachableDevices.isEmpty,
                            )
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
        }
        .task {
            await model.refreshOllama()
            syncPullHost()
        }
        .onChange(of: model.selectedDeviceID) { _, _ in
            syncPullHost()
        }
        .onChange(of: catalog.devices.map(\.hostId)) { _, _ in
            syncPullHost()
        }
        .sheet(item: $startCandidate, onDismiss: { startHostId = "" }) { row in
            startSheet(row)
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
            advertiseHost: model.remoteAccess?.advertiseUrl,
            tailnetHost: InferenceAPIHowTo.tailnetListenHost(model.remoteAccess?.tailscale),
        )
    }

    private var installOses: [String] {
        OllamaInstall.oses(
            installHints: installDevices.map(\.installHint),
            platformOs: model.selectedDevice?.platform?.os
                ?? model.devices.first(where: \.isSelf)?.platform?.os,
        )
    }

    private var installHint: String {
        OllamaInstall.catalogHint(devices: installDevices, os: installOses.first ?? "macos")
    }

    private var installDevices: [OllamaDeviceStatus] {
        OllamaInstall.installDevices(catalog.devices)
    }

    private var deviceInstallLines: [OllamaDeviceStatus] {
        installDevices.filter { !$0.installHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
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
        Section {
            CopyableSnippet(title: "Completions", text: howTo.lanCompletionsURL)
        }
    }

    private func syncPullHost() {
        if let id = model.selectedDevice?.hostId,
           reachableDevices.contains(where: { $0.hostId == id }) {
            pullHostId = id
        } else if pullHostId.isEmpty || !reachableDevices.contains(where: { $0.hostId == pullHostId }) {
            pullHostId = reachableDevices.first?.hostId ?? ""
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

    private func pullModel(name requested: String? = nil) async {
        let name = (requested ?? pullName).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !pullHostId.isEmpty else { return }
        pulling = true
        defer {
            pulling = false
            pullTask = nil
        }
        do {
            let task = try await model.pullOllama(name, hostId: pullHostId)
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
