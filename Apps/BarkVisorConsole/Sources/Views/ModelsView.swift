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

    var body: some View {
        Group {
            if !model.ollamaLoaded {
                ProgressView("Loading Ollama…")
            } else if !catalog.anyReachable {
                ContentUnavailableView(
                    "Ollama is not reachable",
                    systemImage: "cube",
                    description: Text(catalog.devices.first?.installHint ?? "Install Ollama on a Device."),
                )
            } else {
                List {
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
                }
                .platformListStyle()
                .searchable(text: $nameQuery, prompt: "Search models")
            }
        }
        .navigationTitle("Ollama")
        .refreshable { await model.refreshOllama() }
        .task { await model.refreshOllama() }
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
                Task { await model.stopOllama(row.name, hostId: row.locations.first(where: \.running)?.hostId) }
                stopCandidate = nil
            }
            Button("Cancel", role: .cancel) { stopCandidate = nil }
        } message: { row in
            Text("Stop \(row.name) on the \(Copy.device) that is running it?")
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

    @ViewBuilder
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

    private func beginStart(_ row: OllamaCatalogModel) {
        startHostId = ""
        startCandidate = row
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

    var body: some View {
        Picker(Copy.device, selection: $hostId) {
            Text("Any reachable \(Copy.device)").tag("")
            ForEach(devices) { device in
                Text(device.title).tag(device.hostId)
            }
        }
    }
}
