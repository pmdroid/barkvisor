import SwiftUI
import WebKit
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
#endif

enum HostPasteboard {
    static let maxPasteCharacters = 1_000_000

    static func readString() -> String? {
        #if os(iOS)
            UIPasteboard.general.string
        #elseif os(macOS)
            NSPasteboard.general.string(forType: .string)
        #else
            nil
        #endif
    }

    static func writeString(_ text: String) {
        #if os(iOS)
            UIPasteboard.general.string = text
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    static func readData() -> Data? {
        readString()?.data(using: .utf8)
    }

    static func clear() {
        #if os(iOS)
            UIPasteboard.general.items = []
        #elseif os(macOS)
            NSPasteboard.general.clearContents()
        #endif
    }

    static var hasUnreadStrings: Bool {
        #if os(iOS)
            UIPasteboard.general.hasStrings && readString() == nil
        #else
            false
        #endif
    }
}

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
                NoVNCWebView(
                    session: session,
                    pendingScript: session.pendingScript,
                    pendingPaste: session.pendingPaste,
                )
                .background(Color.black)
            } else {
                ContentUnavailableView(
                    access == .deviceUnreachable ? "Device unreachable" : "Display unavailable",
                    systemImage: "display",
                    description: Text(access.reason),
                )
            }
            if access.allowsOpen {
                toolbar
            }
        }
        .navigationTitle("Display")
        #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Keyboard", systemImage: "keyboard") {
                        session.focusKeyboard()
                    }
                    .disabled(!session.connected)
                }
            }
        #endif
            .task(id: WorkloadStream.sessionTaskID(
                deviceID: deviceID,
                workloadID: workloadID,
                state: workload.state,
                deviceReachable: device.isSelf || device.isReachable,
            )) {
                guard let client = model.client, access.allowsOpen else {
                    session.stop()
                    return
                }
                session.start(client: client, workloadID: workload.id, state: workload.state, device: device)
            }
            .onChange(of: workload.state) { _, next in
                session.updateState(next)
            }
            .onDisappear { session.stop() }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.statusLabel)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !session.clipboardHint.isEmpty {
                    Text(session.clipboardHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            HStack {
                Button("Fit") { session.resetZoom() }
                    .disabled(!session.connected || !session.zoomed)
                Button("Paste") { session.pasteFromHost() }
                    .disabled(!session.connected)
                    .help("Paste this computer's clipboard into the guest (desktop guests need spice-vdagent)")
                Button("Copy") { session.copyGuestToHost() }
                    .disabled(session.guestClipboard.isEmpty)
                    .help("Copy the last text the guest put on the clipboard")
                Spacer()
                Button("Keyboard") { session.focusKeyboard() }
                    .disabled(!session.connected)
                Button("Ctrl+Alt+Del") { session.sendCtrlAltDel() }
                    .disabled(!session.connected)
            }
            Text("Desktop guests need spice-vdagent for clipboard.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
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
        WorkloadStreamAccess.resolve(device: device, state: workload.state)
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
    var pendingPaste: String?
    var guestClipboard = ""
    var clipboardHint = ""
    var zoomed = false
    /// True only after the noVNC module posts `ready` (`startVNC` is defined).
    var pageReady = false
    var connectTimeoutNanoseconds: UInt64 = StreamReconnect.connectTimeoutNanoseconds

    private var client: APIClient?
    private var workloadID = ""
    private var device: HomeDeviceHealthSnapshot?
    private var state = ""
    private var stopped = true
    private var attempt = 0
    private var loop: Task<Void, Never>?
    private var waitingForDisconnect = false
    private var scriptQueue: [String] = []
    private var pasteQueue: [String] = []

    var statusLabel: String {
        if connected, !desktopSize.isEmpty { return "VNC · \(desktopSize)" }
        if status.isEmpty { return "VNC" }
        return "VNC · \(status)"
    }

    func start(
        client: APIClient,
        workloadID: String,
        state: String,
        device: HomeDeviceHealthSnapshot? = nil,
    ) {
        stop()
        self.client = client
        self.workloadID = workloadID
        self.device = device
        self.state = state
        stopped = false
        attempt = 0
        loop = Task { await run() }
    }

    func updateState(_ state: String) {
        self.state = state
        if !WorkloadStream.isLive(state) {
            loop?.cancel()
            loop = nil
            discardQueuedWork(resetPageReady: true)
            connected = false
            desktopSize = ""
            zoomed = false
            resetGuestClipboard()
            status = WorkloadStreamAccess.notLive.reason
            waitingForDisconnect = false
        }
    }

    /// Ticket may be used only while this session is still the live stream.
    func canOpenStream() -> Bool {
        !stopped && WorkloadStream.isLive(state)
    }

    /// Test seam: apply a live/not-live state without minting a ticket.
    func primeForTest(state: String) {
        self.state = state
        stopped = false
    }

    func enqueueScript(_ script: String) {
        scriptQueue.append(script)
        pendingScript = script
    }

    func enqueuePaste(_ text: String) {
        pasteQueue.append(text)
        pendingPaste = text
    }

    /// DisplayView keeps `@State session` across live→down→live. Drop queued
    /// JS/paste so a remounted web view cannot flush a prior session.
    private func discardQueuedWork(resetPageReady: Bool) {
        scriptQueue.removeAll()
        pasteQueue.removeAll()
        pendingScript = nil
        pendingPaste = nil
        if resetPageReady {
            pageReady = false
        }
    }

    /// Hands the queued script to the web view. Tests use this as the execute path.
    func consumePendingScript() -> String? {
        guard pageReady else { return nil }
        if !scriptQueue.isEmpty {
            let script = scriptQueue.removeFirst()
            pendingScript = scriptQueue.last
            return script
        }
        guard let script = pendingScript else { return nil }
        pendingScript = nil
        return script
    }

    func consumePendingPaste() -> String? {
        guard pageReady, !pasteQueue.isEmpty else { return nil }
        let text = pasteQueue.removeFirst()
        pendingPaste = pasteQueue.last
        return text
    }

    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
        discardQueuedWork(resetPageReady: true)
        waitingForDisconnect = false
        connected = false
        desktopSize = ""
        zoomed = false
        resetGuestClipboard()
        if status == "connected" || status == "connecting" {
            status = "disconnected"
        }
    }

    func sendCtrlAltDel() {
        enqueueScript("window.sendCtrlAltDel && window.sendCtrlAltDel()")
    }

    func focusKeyboard() {
        enqueueScript("window.focusVNC && window.focusVNC()")
    }

    func resetZoom() {
        enqueueScript("window.resetZoom && window.resetZoom()")
    }

    func pasteFromHost() {
        guard connected else { return }
        if HostPasteboard.hasUnreadStrings {
            clipboardHint = "Allow paste to send the clipboard"
            return
        }
        let text = HostPasteboard.readString() ?? ""
        if text.isEmpty {
            clipboardHint = "Clipboard is empty"
            return
        }
        if text.count > HostPasteboard.maxPasteCharacters {
            clipboardHint = "Clipboard is too large"
            return
        }
        enqueuePaste(text)
        clipboardHint = "Pasted into guest"
    }

    func copyGuestToHost() {
        guard !guestClipboard.isEmpty else { return }
        HostPasteboard.writeString(guestClipboard)
        clipboardHint = "Copied from guest"
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
            zoomed = false
            resetGuestClipboard()
            let width = payload["width"] as? Int ?? 0
            let height = payload["height"] as? Int ?? 0
            desktopSize = width > 0 && height > 0 ? "\(width)×\(height)" : ""
        case "disconnect":
            connected = false
            desktopSize = ""
            zoomed = false
            resetGuestClipboard()
            status = "disconnected"
            waitingForDisconnect = false
            // Web view stays mounted (pageReady kept). Drop unconsumed
            // paste/scripts so auto-reconnect cannot replay them.
            discardQueuedWork(resetPageReady: false)
        case "zoom":
            let scale = zoomScale(payload["scale"])
            zoomed = scale > 1.001
        case "clipboard":
            let oversized = boolFlag(payload["oversized"])
            let text = payload["text"] as? String ?? ""
            if oversized || text.count > HostPasteboard.maxPasteCharacters {
                guestClipboard = ""
                clipboardHint = "Guest clipboard is too large"
                return
            }
            guestClipboard = text
            if !text.isEmpty {
                clipboardHint = "Guest copy ready — use Copy"
            }
        default:
            break
        }
    }

    /// Prior-session guest text must not survive reconnect or a not-live toolbar.
    private func resetGuestClipboard() {
        guestClipboard = ""
        clipboardHint = ""
    }

    private func boolFlag(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return false
    }

    private func zoomScale(_ value: Any?) -> Double {
        if let scale = value as? Double { return scale }
        if let scale = value as? Int { return Double(scale) }
        if let scale = value as? NSNumber { return scale.doubleValue }
        return 1
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
                let tickets = try await client.mintStreamTickets(vmID: workloadID, on: device)
                guard canOpenStream(), !Task.isCancelled else {
                    if !WorkloadStream.isLive(state) {
                        status = WorkloadStreamAccess.notLive.reason
                    }
                    return
                }
                let url = try StreamURL.vnc(
                    base: client.baseURL,
                    workloadID: workloadID,
                    ticket: tickets.ticket,
                    device: device,
                    session: tickets.session,
                )
                // Ticket is allowed in the web view only — never log it.
                let encoded = url.absoluteString.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                enqueueScript("window.startVNC && window.startVNC('\(encoded)')")
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
        waitingForDisconnect = true
        let deadline = ContinuousClock.now + Duration.nanoseconds(Int64(clamping: connectTimeoutNanoseconds))
        while waitingForDisconnect, !Task.isCancelled {
            if connected {
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            if ContinuousClock.now >= deadline {
                expireConnectWaitIfNeeded()
                break
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Resume a stuck connecting wait so the reconnect loop can retry.
    func expireConnectWaitIfNeeded() {
        guard waitingForDisconnect, !connected else { return }
        status = "timed out"
        discardQueuedWork(resetPageReady: false)
        enqueueScript("window.stopVNC && window.stopVNC()")
        waitingForDisconnect = false
    }
}

#if os(iOS)
    struct NoVNCWebView: UIViewRepresentable {
        var session: DisplaySession
        /// Read in `DisplayView` so Keyboard / CAD / paste invalidate the representable.
        var pendingScript: String?
        var pendingPaste: String?

        func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
        }

        func makeUIView(context: Context) -> WKWebView {
            let view = makeWebView(coordinator: context.coordinator)
            context.coordinator.load(view)
            return view
        }

        func updateUIView(_ view: WKWebView, context: Context) {
            _ = pendingScript
            _ = pendingPaste
            context.coordinator.session = session
            context.coordinator.flush(view)
        }
    }
#else
    struct NoVNCWebView: NSViewRepresentable {
        var session: DisplaySession
        /// Read in `DisplayView` so Keyboard / CAD / paste invalidate the representable.
        var pendingScript: String?
        var pendingPaste: String?

        func makeCoordinator() -> Coordinator {
            Coordinator(session: session)
        }

        func makeNSView(context: Context) -> WKWebView {
            let view = makeWebView(coordinator: context.coordinator)
            context.coordinator.load(view)
            return view
        }

        func updateNSView(_ view: WKWebView, context: Context) {
            _ = pendingScript
            _ = pendingPaste
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
    view.underPageBackgroundColor = .black
    #if os(iOS)
        view.isOpaque = true
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 1
        view.scrollView.bouncesZoom = false
        view.scrollView.pinchGestureRecognizer?.isEnabled = false
        view.scrollView.isScrollEnabled = false
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
        while let script = session.consumePendingScript() {
            view.evaluateJavaScript(script, completionHandler: nil)
        }
        while let text = session.consumePendingPaste() {
            view.callAsyncJavaScript(
                "window.pasteClipboard && window.pasteClipboard(text)",
                arguments: ["text": text],
                in: nil,
                in: .page,
                completionHandler: { _ in },
            )
        }
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
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void,
    ) {
        guard let url = navigationAction.request.url, url.isFileURL else {
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }
}
