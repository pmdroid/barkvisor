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
                    ChatHomeWebView(
                        origin: client.baseURL,
                        token: token,
                        refreshToken: model.sessionRefreshToken ?? "",
                        onAdoptSession: { access, refresh in
                            model.adoptWebSession(token: access, refreshToken: refresh)
                        },
                        onNativeRefresh: {
                            await model.refreshSessionFromWeb()
                        },
                    )
                    .id(ChatWebSession.viewIdentity(home: client.baseURL))
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
        var refreshToken: String
        var onAdoptSession: (String, String) -> Void
        var onNativeRefresh: () async -> SessionTokens?

        func makeCoordinator() -> ChatHomeWebCoordinator {
            ChatHomeWebCoordinator(
                origin: origin,
                token: token,
                refreshToken: refreshToken,
                onAdoptSession: onAdoptSession,
                onNativeRefresh: onNativeRefresh,
            )
        }

        func makeUIView(context: Context) -> WKWebView {
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            config.defaultWebpagePreferences.allowsContentJavaScript = true
            config.userContentController.add(
                context.coordinator,
                name: ChatWebSession.messageHandlerName,
            )
            let view = WKWebView(frame: .zero, configuration: config)
            view.navigationDelegate = context.coordinator
            view.isOpaque = false
            view.backgroundColor = .systemBackground
            view.scrollView.keyboardDismissMode = .interactive
            context.coordinator.applySession(
                token: token,
                refreshToken: refreshToken,
                to: view,
                loadIfNeeded: true,
            )
            return view
        }

        func updateUIView(_ view: WKWebView, context: Context) {
            context.coordinator.onAdoptSession = onAdoptSession
            context.coordinator.onNativeRefresh = onNativeRefresh
            context.coordinator.applySession(
                token: token,
                refreshToken: refreshToken,
                to: view,
                loadIfNeeded: false,
            )
        }

        static func dismantleUIView(_ view: WKWebView, coordinator: ChatHomeWebCoordinator) {
            view.configuration.userContentController.removeScriptMessageHandler(
                forName: ChatWebSession.messageHandlerName,
            )
            coordinator.webView = nil
        }
    }

    @MainActor
    final class ChatHomeWebCoordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private let homeOrigin: URL
        private var token: String
        private var refreshToken: String
        private var loaded = false
        private var scriptsInstalled = false
        var onAdoptSession: (String, String) -> Void
        var onNativeRefresh: () async -> SessionTokens?
        weak var webView: WKWebView?

        init(
            origin: URL,
            token: String,
            refreshToken: String,
            onAdoptSession: @escaping (String, String) -> Void,
            onNativeRefresh: @escaping () async -> SessionTokens?,
        ) {
            homeOrigin = origin
            self.token = token
            self.refreshToken = refreshToken
            self.onAdoptSession = onAdoptSession
            self.onNativeRefresh = onNativeRefresh
        }

        func applySession(token: String, refreshToken: String, to view: WKWebView, loadIfNeeded: Bool) {
            webView = view
            let changed = self.token != token || self.refreshToken != refreshToken
            self.token = token
            self.refreshToken = refreshToken
            if changed || !scriptsInstalled {
                installScripts(on: view)
                if let cookie = ChatWebSession.cookie(home: homeOrigin, token: token) {
                    view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
                }
            }
            if !loaded {
                if loadIfNeeded {
                    installContentRulesThenLoad(view)
                }
                return
            }
            if changed {
                notifySession(to: view)
            }
        }

        private func installContentRulesThenLoad(_ view: WKWebView) {
            let json = ChatWebSession.homeOnlyContentRules(home: homeOrigin)
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "barkvisor-chat-home-\(homeOrigin.host ?? "origin")",
                encodedContentRuleList: json,
            ) { [weak self] list, _ in
                Task { @MainActor in
                    if let list {
                        view.configuration.userContentController.add(list)
                    }
                    self?.load(view)
                }
            }
        }

        func notifySession(to view: WKWebView) {
            view.evaluateJavaScript(
                ChatWebSession.userScriptSource(token: token, refreshToken: refreshToken),
                completionHandler: nil,
            )
        }

        private func installScripts(on view: WKWebView) {
            let controller = view.configuration.userContentController
            if scriptsInstalled {
                controller.removeAllUserScripts()
            }
            controller.addUserScript(
                WKUserScript(
                    source: ChatWebSession.userScriptSource(token: token, refreshToken: refreshToken),
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: false,
                ),
            )
            scriptsInstalled = true
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

        private func handleBridgeMessage(_ body: Any, from view: WKWebView?) {
            guard let parsed = ChatWebSession.parseBridgeMessage(body) else { return }
            switch parsed {
            case .refresh:
                Task { @MainActor in
                    let session = await onNativeRefresh()
                    guard let target = view ?? webView else { return }
                    if let session {
                        applySession(
                            token: session.token,
                            refreshToken: session.refreshToken,
                            to: target,
                            loadIfNeeded: false,
                        )
                    }
                    notifySession(to: target)
                }
            case let .session(token, refreshToken):
                onAdoptSession(token, refreshToken)
                self.token = token
                self.refreshToken = refreshToken
            }
        }

        nonisolated func userContentController(
            _: WKUserContentController,
            didReceive message: WKScriptMessage,
        ) {
            let body = message.body
            let webView = message.webView
            Task { @MainActor in
                self.handleBridgeMessage(body, from: webView)
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
            Task { @MainActor in
                let secrets = ChatWebSession.navigationSecrets(
                    token: self.token,
                    refreshToken: self.refreshToken,
                )
                let allow = ChatWebSession.allowsNavigation(url, home: self.homeOrigin, secrets: secrets)
                decisionHandler(allow ? .allow : .cancel)
            }
        }
    }
#endif
