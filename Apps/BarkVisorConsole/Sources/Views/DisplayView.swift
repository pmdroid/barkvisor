import SwiftUI
import WebKit

struct DisplayView: View {
    @Environment(AppModel.self) private var model
    var workloadID: String
    var deviceID: String
    var fallbackWorkload: Workload
    var fallbackDevice: HomeDeviceHealthSnapshot
    @State private var session = DisplaySession()

    var body: some View {
        VStack(spacing: 0) {
            if access.allowsOpen {
                NoVNCWebView(session: session)
                    .background(Color.black)
            } else {
                ContentUnavailableView(
                    access == .memberDisabled ? "Member Display unavailable" : "Display unavailable",
                    systemImage: "display",
                    description: Text(access.reason)
                )
            }
            if access.allowsOpen {
                HStack {
                    Text(session.statusLabel)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Ctrl+Alt+Del") { session.sendCtrlAltDel() }
                        .disabled(!session.connected)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .navigationTitle("Display")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: "\(deviceID)/\(workloadID)/\(workload.state)") {
            guard let client = model.client, access.allowsOpen else {
                session.stop()
                return
            }
            session.start(client: client, workloadID: workload.id, state: workload.state)
        }
        .onChange(of: workload.state) { _, next in
            session.updateState(next)
        }
        .onDisappear { session.stop() }
    }

    private var workload: Workload {
        if let home = model.homeRows.first(where: { $0.workload.id == workloadID && $0.device.hostId == deviceID }) {
            return home.workload
        }
        if model.selectedDevice?.hostId == deviceID, let live = model.workloads.first(where: { $0.id == workloadID }) {
            return live
        }
        return fallbackWorkload
    }

    private var device: HomeDeviceHealthSnapshot {
        model.devices.first(where: { $0.hostId == deviceID }) ?? fallbackDevice
    }

    private var access: WorkloadStreamAccess {
        WorkloadStreamAccess.resolve(isSelfDevice: device.isSelf, state: workload.state)
    }
}

/// Owns ticket minting and reconnect. The session JWT never enters the web view.
@Observable
@MainActor
final class DisplaySession {
    var status = "disconnected"
    var desktopSize = ""
    var connected = false
    var pendingScript: String?
    /// True only after the noVNC module posts `ready` (`startVNC` is defined).
    var pageReady = false
    var connectTimeoutNanoseconds: UInt64 = StreamReconnect.connectTimeoutNanoseconds

    private var client: APIClient?
    private var workloadID = ""
    private var state = ""
    private var stopped = true
    private var attempt = 0
    private var loop: Task<Void, Never>?
    private var waitForDisconnect: CheckedContinuation<Void, Never>?
    private var connectTimeout: Task<Void, Never>?

    var statusLabel: String {
        if connected, !desktopSize.isEmpty { return "VNC · \(desktopSize)" }
        if status.isEmpty { return "VNC" }
        return "VNC · \(status)"
    }

    func start(client: APIClient, workloadID: String, state: String) {
        stop()
        self.client = client
        self.workloadID = workloadID
        self.state = state
        stopped = false
        attempt = 0
        loop = Task { await run() }
    }

    func updateState(_ state: String) {
        self.state = state
        if !WorkloadStream.isLive(state) {
            pendingScript = "window.stopVNC && window.stopVNC()"
            connected = false
            desktopSize = ""
            status = WorkloadStreamAccess.notLive.reason
        }
    }

    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
        pendingScript = "window.stopVNC && window.stopVNC()"
        resumeDisconnectWaiter()
        connected = false
    }

    func sendCtrlAltDel() {
        pendingScript = "window.sendCtrlAltDel && window.sendCtrlAltDel()"
    }

    func handleMessage(_ body: Any) {
        guard let payload = body as? [String: Any], let type = payload["type"] as? String else { return }
        switch type {
        case "ready":
            pageReady = true
        case "connect":
            connected = true
            attempt = 0
            status = "connected"
            connectTimeout?.cancel()
            connectTimeout = nil
            let width = payload["width"] as? Int ?? 0
            let height = payload["height"] as? Int ?? 0
            desktopSize = width > 0 && height > 0 ? "\(width)×\(height)" : ""
        case "disconnect":
            connected = false
            desktopSize = ""
            resumeDisconnectWaiter()
        default:
            break
        }
    }

    private func run() async {
        while !stopped, !Task.isCancelled {
            guard WorkloadStream.isLive(state) else {
                status = WorkloadStreamAccess.notLive.reason
                return
            }
            guard let client else { return }
            do {
                status = "requesting ticket"
                let ticket = try await client.createWSTicket(vmID: workloadID)
                let url = try StreamURL.vnc(base: client.baseURL, workloadID: workloadID, ticket: ticket)
                // Ticket is allowed in the web view only — never log it.
                let encoded = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                pendingScript = "window.startVNC && window.startVNC('\(encoded)')"
                status = "connecting"
                await waitUntilDisconnected()
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
            guard !stopped, !Task.isCancelled else { return }
            guard WorkloadStream.isLive(state) else {
                status = WorkloadStreamAccess.notLive.reason
                return
            }
            attempt += 1
            guard StreamReconnect.shouldRetry(attempt: attempt) else {
                status = "max reconnects"
                return
            }
            status = "reconnecting (\(attempt)/\(StreamReconnect.maxAttempts))"
            try? await Task.sleep(nanoseconds: StreamReconnect.delayNanoseconds(attempt: attempt))
        }
    }

    func waitUntilDisconnected() async {
        await withCheckedContinuation { continuation in
            waitForDisconnect = continuation
            armConnectTimeout()
        }
    }

    /// Resume a stuck connecting wait so the reconnect loop can retry.
    func expireConnectWaitIfNeeded() {
        guard waitForDisconnect != nil, !connected else { return }
        status = "timed out"
        pendingScript = "window.stopVNC && window.stopVNC()"
        resumeDisconnectWaiter()
    }

    private func armConnectTimeout() {
        connectTimeout?.cancel()
        let timeout = connectTimeoutNanoseconds
        connectTimeout = Task { @MainActor in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled, !stopped else { return }
            expireConnectWaitIfNeeded()
        }
    }

    private func resumeDisconnectWaiter() {
        connectTimeout?.cancel()
        connectTimeout = nil
        waitForDisconnect?.resume()
        waitForDisconnect = nil
    }
}

#if os(iOS)
struct NoVNCWebView: UIViewRepresentable {
    var session: DisplaySession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> WKWebView {
        let view = makeWebView(coordinator: context.coordinator)
        context.coordinator.load(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.session = session
        context.coordinator.flush(view)
    }
}
#else
struct NoVNCWebView: NSViewRepresentable {
    var session: DisplaySession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> WKWebView {
        let view = makeWebView(coordinator: context.coordinator)
        context.coordinator.load(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.session = session
        context.coordinator.flush(view)
    }
}
#endif

private func makeWebView(coordinator: Coordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.defaultWebpagePreferences.allowsContentJavaScript = true
    config.userContentController.add(coordinator, name: "novnc")
    config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
    let view = WKWebView(frame: .zero, configuration: config)
    view.navigationDelegate = coordinator
    view.isOpaque = true
    view.underPageBackgroundColor = .black
    #if os(iOS)
    view.scrollView.contentInsetAdjustmentBehavior = .never
    view.backgroundColor = .black
    #endif
    return view
}

@MainActor
final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var session: DisplaySession
    private var loaded = false

    init(session: DisplaySession) {
        self.session = session
    }

    func load(_ view: WKWebView) {
        guard !loaded else { return }
        guard let html = Bundle.main.url(forResource: "vnc", withExtension: "html", subdirectory: "noVNC") else {
            session.status = "bundled noVNC is missing"
            return
        }
        loaded = true
        view.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
    }

    func flush(_ view: WKWebView) {
        guard session.pageReady, let script = session.pendingScript else { return }
        session.pendingScript = nil
        view.evaluateJavaScript(script, completionHandler: nil)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        Task { @MainActor in
            // HTML load is not enough: startVNC is assigned after the module import.
            flush(webView)
        }
    }

    nonisolated func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let webView = message.webView
        Task { @MainActor in
            session.handleMessage(body)
            if let webView {
                flush(webView)
            }
        }
    }

    nonisolated func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url, url.isFileURL else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
