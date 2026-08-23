import SwiftUI

struct ChatView: View {
    @Environment(AppModel.self) private var model
    @State private var modelName = ""
    @State private var draft = ""
    @State private var turns: [ChatTurn] = []
    @State private var streaming = false
    @State private var streamGeneration = 0
    @State private var error: String?
    @State private var sendTask: Task<Void, Never>?

    var body: some View {
        Group {
            if !model.showsChat {
                ContentUnavailableView(
                    "Chat is hidden",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Install Ollama and pull a model on a Device. Completions use /v1/chat/completions."),
                )
            } else {
                chatBody
            }
        }
        .task(id: model.showsChat) {
            await model.refreshOllamaCatalog()
            pickDefaultModel()
        }
        .onChange(of: model.ollamaCatalog) { _, _ in
            pickDefaultModel()
        }
    }

    private var chatBody: some View {
        VStack(spacing: 0) {
            Picker("Model", selection: $modelName) {
                ForEach(model.ollamaCatalog?.models ?? []) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .pickerStyle(.menu)
            .disabled(streaming)
            .padding(.horizontal)
            .padding(.top, 8)

            if turns.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "text.bubble",
                    description: Text("Pick a model and send a prompt. Tokens stream as they arrive."),
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(turns) { turn in
                                VStack(alignment: turn.isUser ? .trailing : .leading, spacing: 4) {
                                    Text(turn.isUser ? "You" : modelName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(turn.content.isEmpty ? "…" : turn.content)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: turn.isUser ? .trailing : .leading)
                                }
                                .id(turn.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: turns.last?.content) { _, _ in
                        if let id = turns.last?.id {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }

            if let error {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }

            HStack(alignment: .bottom) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 5)
                    .textFieldStyle(.roundedBorder)
                    .disabled(modelName.isEmpty)
                    .onSubmit { send() }
                if streaming {
                    Button("Stop") { stopStreaming() }
                } else {
                    Button("Send") { send() }
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || modelName.isEmpty)
                }
            }
            .padding()
        }
    }

    private func pickDefaultModel() {
        let names = model.ollamaCatalog?.models.map(\.name) ?? []
        if !names.contains(modelName) {
            modelName = ChatAvailability.defaultModel(in: model.ollamaCatalog)
        }
    }

    private func stopStreaming() {
        streamGeneration += 1
        sendTask?.cancel()
        streaming = false
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !modelName.isEmpty, !streaming else { return }
        guard let client = model.client else {
            error = "Sign in required"
            return
        }
        draft = ""
        error = nil
        streamGeneration += 1
        let generation = streamGeneration
        let user = ChatTurn(role: "user", content: text)
        let assistant = ChatTurn(role: "assistant", content: "")
        let assistantID = assistant.id
        turns.append(user)
        turns.append(assistant)
        let history = turns.dropLast().map { ChatWireMessage(role: $0.role, content: $0.content) }
        streaming = true
        sendTask = Task { @MainActor in
            defer {
                if generation == streamGeneration {
                    streaming = false
                }
            }
            do {
                try await client.streamChatCompletions(
                    model: modelName,
                    messages: Array(history),
                ) { delta in
                    Task { @MainActor in
                        ChatStreamApply.append(
                            delta: delta,
                            to: &turns,
                            assistantID: assistantID,
                            generation: generation,
                            currentGeneration: streamGeneration,
                        )
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
                if turns.last?.content.isEmpty == true {
                    turns.removeLast()
                    if turns.last?.isUser == true {
                        draft = text
                        turns.removeLast()
                    }
                }
            }
        }
    }
}
