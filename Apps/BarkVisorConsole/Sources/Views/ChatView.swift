import SwiftUI
#if os(iOS)
    import WebKit
#endif

struct ChatView: View {
    var body: some View {
        #if os(iOS)
            ChatWebView()
        #else
            ChatNativeView()
        #endif
    }
}

/// Mac Chat stays the SwiftUI `/v1/chat/completions` streamer (GitHub #228).
struct ChatNativeView: View {
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
        .navigationTitle("Chat")
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
        sendTask = Task {
            do {
                try await client.streamChatCompletions(
                    model: modelName,
                    messages: Array(history),
                ) { delta in
                    await MainActor.run {
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
            } catch {
                await MainActor.run {
                    guard generation == streamGeneration else { return }
                    self.error = error.localizedDescription
                    ChatStreamApply.rollbackFailedSend(
                        turns: &turns,
                        draft: &draft,
                        originalText: text,
                        assistantID: assistantID,
                        generation: generation,
                        currentGeneration: streamGeneration,
                    )
                }
            }
            await MainActor.run {
                if generation == streamGeneration {
                    streaming = false
                }
            }
        }
    }
}

#if os(iOS)
    /// iOS Chat tab: Home origin `/chat` in WKWebView. No third Swift streamer.
    struct ChatWebView: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            Group {
                if !model.showsChat {
                    ContentUnavailableView(
                        "Chat is hidden",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "Install Ollama and pull a model on a Device. Completions use /v1/chat/completions.",
                        ),
                    )
                } else if let client = model.client, let token = client.token, !token.isEmpty {
                    ChatHomeWebView(origin: client.baseURL, token: token)
                        .id(client.baseURL.absoluteString + "\u{1e}" + token)
                } else {
                    ContentUnavailableView(
                        "Sign in required",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Chat uses the same session as this Console."),
                    )
                }
            }
            .navigationTitle("Chat")
            .task(id: model.showsChat) {
                await model.refreshOllamaCatalog()
            }
        }
    }

    struct ChatHomeWebView: UIViewRepresentable {
        var origin: URL
        var token: String

        func makeCoordinator() -> ChatHomeWebCoordinator {
            ChatHomeWebCoordinator(origin: origin, token: token)
        }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.userContentController.addUserScript(
                WKUserScript(
                    source: ChatWebSession.userScriptSource(token: token),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                ),
            )
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator
            view.isOpaque = false
            view.backgroundColor = .systemBackground
            view.scrollView.keyboardDismissMode = .interactive
            context.coordinator.load(view)
            return view
        }

        func updateUIView(_: WKWebView, context _: Context) {}
    }

    final class ChatHomeWebCoordinator: NSObject, WKNavigationDelegate {
        private let homeOrigin: URL
        private let token: String
        private var loaded = false

        init(origin: URL, token: String) {
            homeOrigin = origin
            self.token = token
        }

        func load(_ view: WKWebView) {
            guard !loaded else { return }
            guard let request = try? ChatWebSession.pageRequest(home: homeOrigin, token: token) else { return }
            loaded = true
            if let cookie = ChatWebSession.cookie(home: homeOrigin, token: token) {
                view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
                    Task { @MainActor in
                        view.load(request)
                    }
                }
            } else {
                view.load(request)
            }
        }

        nonisolated func webView(
            _: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme?.lowercased() == "about" {
                decisionHandler(.allow)
                return
            }
            if ChatWebSession.isHomeOrigin(url, home: homeOrigin) {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
#endif
