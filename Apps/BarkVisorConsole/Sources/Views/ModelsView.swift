import SwiftUI

struct ModelsView: View {
    @Environment(AppModel.self) private var model
    @State private var pullName = ""
    @State private var pullHostId = ""
    @State private var pulling = false
    @State private var cancelling = false
    @State private var pullTask: OllamaTaskAccepted?
    @State private var pullEvent: OllamaTaskEvent?

    var body: some View {
        content
            .refreshable { await model.refreshOllama() }
            .task { await model.refreshOllama() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.ollamaLoaded {
            ProgressView("Loading Ollama…")
        } else if model.ollamaCatalog?.anyReachable != true {
                ContentUnavailableView(
                    "Ollama is not reachable",
                    systemImage: "cube",
                    description: Text(model.ollamaCatalog?.devices.first?.installHint ?? "Install Ollama on a Device."),
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                Form {
                    Section("Pull a model") {
                        TextField("llama3", text: $pullName)
                        Picker(Copy.device, selection: $pullHostId) {
                            Text("Any reachable \(Copy.device)").tag("")
                            ForEach(reachableOllamaDevices, id: \.hostId) { device in
                                Text(device.title).tag(device.hostId)
                            }
                        }
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
                }
                OllamaCatalogRows(
                    models: catalogModels,
                    actionIDs: model.actionIDs,
                    onStart: { name in
                        Task { await model.startOllama(name) }
                    },
                    onStop: { name, hostId in
                        Task { await model.stopOllama(name, hostId: hostId) }
                    },
                )
                Spacer(minLength: 0)
                }
            }
    }

    private var catalogModels: [OllamaCatalogModel] {
        model.ollamaCatalog?.models ?? []
    }

    private var reachableOllamaDevices: [OllamaDeviceStatus] {
        (model.ollamaCatalog?.devices ?? []).filter(\.reachable)
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

private struct OllamaCatalogRows: View {
    let models: [OllamaCatalogModel]
    var actionIDs: Set<String>
    var onStart: (String) -> Void
    var onStop: (String, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
        Text("Models")
            .font(.headline)
            .padding(.horizontal)
            .padding(.top, 12)
        if models.isEmpty {
            Text("Pull a model to use chat completions through BarkVisor.")
                .foregroundStyle(.secondary)
                .padding(.horizontal)
        } else {
            ForEach(models, id: \.name) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.name).fontWeight(.medium)
                        Text(row.locationLine)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.running ? "Running" : "Pulled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if row.running {
                        Button("Stop") {
                            onStop(row.name, row.locations.first(where: \.running)?.hostId)
                        }
                        .disabled(actionIDs.contains("ollama/\(row.name)"))
                    } else {
                        Button("Start") {
                            onStart(row.name)
                        }
                        .disabled(actionIDs.contains("ollama/\(row.name)"))
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }
        }
        }
    }
}
