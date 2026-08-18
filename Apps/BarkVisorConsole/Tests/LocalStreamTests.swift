import Foundation
import Testing
@testable import BarkVisorConsole

struct LocalStreamTests {
    @Test func streamLiveOnlyWhenRunningOrStopping() {
        #expect(WorkloadStream.isLive("running"))
        #expect(WorkloadStream.isLive("stopping"))
        #expect(!WorkloadStream.isLive("stopped"))
        #expect(!WorkloadStream.isLive("starting"))
        #expect(!WorkloadStream.isLive("error"))
    }

    @Test func sessionTaskIDIgnoresRunningToStopping() {
        let running = WorkloadStream.sessionTaskID(deviceID: "self", workloadID: "vm-1", state: "running")
        let stopping = WorkloadStream.sessionTaskID(deviceID: "self", workloadID: "vm-1", state: "stopping")
        let stopped = WorkloadStream.sessionTaskID(deviceID: "self", workloadID: "vm-1", state: "stopped")
        let other = WorkloadStream.sessionTaskID(deviceID: "self", workloadID: "vm-2", state: "running")
        #expect(running == stopping)
        #expect(running != stopped)
        #expect(running != other)
        #expect(running.hasSuffix("/live"))
        #expect(stopped.hasSuffix("/down"))
    }

    @Test func memberStreamsStayDisabled() {
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: false, state: "running") == .memberDisabled)
        #expect(!WorkloadStreamAccess.resolve(isSelfDevice: false, state: "running").allowsOpen)
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "stopped") == .notLive)
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "running") == .available)
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "stopping") == .available)
        #expect(
            WorkloadStreamAccess.memberDisabled.reason
                == "Console and Display on a member Device are not available yet."
        )
    }

    @Test func reconnectBackoffCapsAtTenAttempts() {
        #expect(StreamReconnect.maxAttempts == 10)
        #expect(!StreamReconnect.shouldRetry(attempt: 0))
        #expect(StreamReconnect.shouldRetry(attempt: 1))
        #expect(StreamReconnect.shouldRetry(attempt: 10))
        #expect(!StreamReconnect.shouldRetry(attempt: 11))
        #expect(StreamReconnect.delayNanoseconds(attempt: 1) == 1_000_000_000)
        #expect(StreamReconnect.delayNanoseconds(attempt: 2) == 2_000_000_000)
        #expect(StreamReconnect.delayNanoseconds(attempt: 3) == 4_000_000_000)
        #expect(StreamReconnect.delayNanoseconds(attempt: 6) == 30_000_000_000)
        #expect(StreamReconnect.delayNanoseconds(attempt: 10) == 30_000_000_000)
        #expect(StreamReconnect.connectTimeoutNanoseconds == 15_000_000_000)
        #expect(StreamReconnect.connectTimeoutNanoseconds < StreamReconnect.maxDelayNanoseconds)
    }

    @Test @MainActor func displayReadyMessageMarksModuleReady() {
        let session = DisplaySession()
        session.pendingScript = "window.startVNC && window.startVNC('ws://example')"
        session.handleMessage(["type": "connect", "width": 800, "height": 600])
        #expect(!session.pageReady)
        #expect(session.pendingScript != nil)
        session.handleMessage(["type": "ready"])
        #expect(session.pageReady)
        #expect(session.pendingScript != nil)
    }

    @Test @MainActor func displayConnectTimeoutResumesWaiter() async {
        let session = DisplaySession()
        session.connectTimeoutNanoseconds = 10_000_000
        session.status = "connecting"
        await session.waitUntilDisconnected()
        #expect(session.status == "timed out")
        #expect(session.pendingScript == "window.stopVNC && window.stopVNC()")
        #expect(!session.connected)
    }

    @Test @MainActor func displayConnectTimeoutSkippedAfterConnect() async {
        let session = DisplaySession()
        session.connectTimeoutNanoseconds = 20_000_000
        async let wait: Void = session.waitUntilDisconnected()
        session.handleMessage(["type": "connect", "width": 1024, "height": 768])
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(session.connected)
        #expect(session.status == "connected")
        session.handleMessage(["type": "disconnect"])
        await wait
        #expect(!session.connected)
        #expect(session.status == "disconnected")
    }

    @Test @MainActor func displayStopClearsConnectedToolbar() {
        let session = DisplaySession()
        session.handleMessage(["type": "connect", "width": 1280, "height": 800])
        #expect(session.statusLabel == "VNC · 1280×800")
        session.stop()
        #expect(!session.connected)
        #expect(session.desktopSize.isEmpty)
        #expect(session.status == "disconnected")
        #expect(session.statusLabel == "VNC · disconnected")
        #expect(session.pendingScript == nil)
        #expect(!session.pageReady)
    }

    @Test @MainActor func displayControlScriptsTargetGuest() {
        let session = DisplaySession()
        session.sendCtrlAltDel()
        #expect(session.pendingScript == "window.sendCtrlAltDel && window.sendCtrlAltDel()")
        session.focusKeyboard()
        #expect(session.pendingScript == "window.focusVNC && window.focusVNC()")
        session.resetZoom()
        #expect(session.pendingScript == "window.resetZoom && window.resetZoom()")
    }

    @Test @MainActor func displayControlScriptsStayQueuedInOrder() {
        let session = DisplaySession()
        session.pageReady = true
        session.sendCtrlAltDel()
        session.focusKeyboard()
        session.resetZoom()
        #expect(session.consumePendingScript() == "window.sendCtrlAltDel && window.sendCtrlAltDel()")
        #expect(session.consumePendingScript() == "window.focusVNC && window.focusVNC()")
        #expect(session.consumePendingScript() == "window.resetZoom && window.resetZoom()")
        #expect(session.consumePendingScript() == nil)
        #expect(session.pendingScript == nil)
    }

    @Test @MainActor func displayZoomMessageTogglesFit() {
        let session = DisplaySession()
        session.handleMessage(["type": "zoom", "scale": 2])
        #expect(session.zoomed)
        session.handleMessage(["type": "zoom", "scale": 1])
        #expect(!session.zoomed)
        session.handleMessage(["type": "zoom", "scale": 1.5])
        #expect(session.zoomed)
        session.handleMessage(["type": "disconnect"])
        #expect(!session.zoomed)
    }

    @Test @MainActor func displayControlScriptsExecuteOnlyWhenPageReady() {
        let session = DisplaySession()
        session.sendCtrlAltDel()
        #expect(session.consumePendingScript() == nil)
        #expect(session.pendingScript == "window.sendCtrlAltDel && window.sendCtrlAltDel()")

        session.pageReady = true
        #expect(session.consumePendingScript() == "window.sendCtrlAltDel && window.sendCtrlAltDel()")
        #expect(session.pendingScript == nil)

        session.focusKeyboard()
        #expect(session.consumePendingScript() == "window.focusVNC && window.focusVNC()")
        #expect(session.pendingScript == nil)
        #expect(session.consumePendingScript() == nil)
    }

    @Test @MainActor func displayStopDiscardsQueuedScriptsAndPaste() {
        let session = DisplaySession()
        session.pageReady = true
        session.sendCtrlAltDel()
        session.enqueuePaste("leftover-paste")
        #expect(session.pendingScript != nil)
        #expect(session.pendingPaste == "leftover-paste")

        session.stop()
        #expect(!session.pageReady)
        #expect(session.pendingScript == nil)
        #expect(session.pendingPaste == nil)
        session.pageReady = true
        #expect(session.consumePendingScript() == nil)
        #expect(session.consumePendingPaste() == nil)
    }

    @Test @MainActor func displayStartDiscardsQueuedWorkFromPriorSession() {
        let session = DisplaySession()
        session.pageReady = true
        session.sendCtrlAltDel()
        session.enqueuePaste("stale-paste")

        let client = APIClient(baseURL: URL(string: "http://127.0.0.1:9")!, token: nil)
        session.start(client: client, workloadID: "vm-1", state: "running")
        #expect(!session.pageReady)
        #expect(session.pendingScript == nil)
        #expect(session.pendingPaste == nil)
        session.pageReady = true
        #expect(session.consumePendingScript() == nil)
        #expect(session.consumePendingPaste() == nil)
        session.stop()
    }

    @Test @MainActor func displayNotLiveDiscardsQueuedWorkAndPageReady() {
        let session = DisplaySession()
        session.primeForTest(state: "running")
        session.pageReady = true
        session.sendCtrlAltDel()
        session.enqueuePaste("stale-paste")

        session.updateState("stopped")
        #expect(!session.pageReady)
        #expect(session.pendingScript == nil)
        #expect(session.pendingPaste == nil)
        session.pageReady = true
        #expect(session.consumePendingScript() == nil)
        #expect(session.consumePendingPaste() == nil)
    }

    @Test @MainActor func displayConnectTimeoutDropsLeftoversThenStopsVNC() async {
        let session = DisplaySession()
        session.connectTimeoutNanoseconds = 10_000_000
        session.pageReady = true
        session.enqueuePaste("stale-paste")
        session.sendCtrlAltDel()
        #expect(session.pendingPaste == "stale-paste")
        #expect(session.pendingScript == "window.sendCtrlAltDel && window.sendCtrlAltDel()")

        await session.waitUntilDisconnected()
        #expect(session.status == "timed out")
        #expect(session.pageReady)
        #expect(session.pendingPaste == nil)
        #expect(session.pendingScript == "window.stopVNC && window.stopVNC()")
        #expect(session.consumePendingPaste() == nil)
        #expect(session.consumePendingScript() == "window.stopVNC && window.stopVNC()")
        #expect(session.consumePendingScript() == nil)
    }

    @Test @MainActor func displayDropsTicketWhenWorkloadLeavesLive() {
        let session = DisplaySession()
        session.primeForTest(state: "running")
        #expect(session.canOpenStream())
        session.updateState("stopping")
        #expect(session.canOpenStream())
        session.updateState("stopped")
        #expect(!session.canOpenStream())
        #expect(session.status == WorkloadStreamAccess.notLive.reason)
        #expect(session.pendingScript == nil)
        #expect(!session.pageReady)
    }

    @Test @MainActor func consoleDropsTicketWhenWorkloadLeavesLive() {
        let session = ConsoleSession()
        session.primeForTest(state: "running")
        #expect(session.canOpenStream())
        session.updateState("stopping")
        #expect(session.canOpenStream())
        session.updateState("stopped")
        #expect(!session.canOpenStream())
        #expect(session.status == WorkloadStreamAccess.notLive.reason)
    }

    @Test func streamURLUsesTicketAndNeverJWT() throws {
        let base = try DeviceURL.normalize("http://192.168.30.1:7777")
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImV4cCI6OTk5OTk5OTk5OX0.sig"
        let console = try StreamURL.console(base: base, workloadID: "vm-1", ticket: "ticket-one")
        let display = try StreamURL.vnc(base: base, workloadID: "vm-1", ticket: "ticket-one")

        #expect(console.scheme == "ws")
        #expect(console.path == "/api/vms/vm-1/console")
        #expect(console.query == "ticket=ticket-one")
        #expect(!console.path.contains("/home/devices/"))
        #expect(!StreamURL.containsSecret(console, secret: jwt))
        #expect(!console.absoluteString.contains("Bearer"))

        #expect(display.scheme == "ws")
        #expect(display.path == "/api/vms/vm-1/vnc")
        #expect(display.query == "ticket=ticket-one")
        #expect(!StreamURL.containsSecret(display, secret: jwt))

        let secure = try StreamURL.console(
            base: DeviceURL.normalize("https://home.local:7777"),
            workloadID: "vm-2",
            ticket: "tick+et"
        )
        #expect(secure.scheme == "wss")
        #expect(secure.absoluteString.contains("ticket=tick"))
        #expect(!StreamURL.containsSecret(secure, secret: jwt))
    }

    @Test func wsTicketResponseDecodes() throws {
        let body = try JSONDecoder().decode(
            WSTicketResponse.self,
            from: Data(#"{"ticket":"one-shot"}"#.utf8)
        )
        #expect(body.ticket == "one-shot")
    }
}

@Suite(.serialized)
struct DisplayClipboardTests {
    @Test @MainActor func displayClipboardBuffersGuestText() {
        let session = DisplaySession()
        session.handleMessage(["type": "clipboard", "text": "guest-copy"])
        #expect(session.guestClipboard == "guest-copy")
        #expect(session.clipboardHint == "Guest copy ready — use Copy")
        session.copyGuestToHost()
        #expect(HostPasteboard.readString() == "guest-copy")
        #expect(session.clipboardHint == "Copied from guest")
    }

    @Test @MainActor func displayClipboardClearsOnDisconnect() {
        let session = DisplaySession()
        let sentinel = "pas-220-host-\(UUID().uuidString)"
        HostPasteboard.writeString(sentinel)
        session.handleMessage(["type": "clipboard", "text": "guest-copy"])
        session.handleMessage(["type": "disconnect"])
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint.isEmpty)
        session.copyGuestToHost()
        #expect(HostPasteboard.readString() == sentinel)
    }

    @Test @MainActor func displayClipboardClearsOnConnect() {
        let session = DisplaySession()
        session.handleMessage(["type": "clipboard", "text": "stale-guest"])
        session.handleMessage(["type": "connect", "width": 800, "height": 600])
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint.isEmpty)
    }

    @Test @MainActor func displayClipboardClearsOnStop() {
        let session = DisplaySession()
        session.handleMessage(["type": "clipboard", "text": "guest-copy"])
        session.stop()
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint.isEmpty)
    }

    @Test @MainActor func displayClipboardClearsWhenNotLive() {
        let session = DisplaySession()
        session.primeForTest(state: "running")
        session.handleMessage(["type": "clipboard", "text": "guest-copy"])
        session.updateState("stopped")
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint.isEmpty)
    }

    @Test @MainActor func displayClipboardRejectsOversizedGuestPayload() {
        let session = DisplaySession()
        let sentinel = "pas-220-host-\(UUID().uuidString)"
        HostPasteboard.writeString(sentinel)
        let oversized = String(repeating: "a", count: HostPasteboard.maxPasteCharacters + 1)
        session.handleMessage(["type": "clipboard", "text": oversized])
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint == "Guest clipboard is too large")
        session.copyGuestToHost()
        #expect(HostPasteboard.readString() == sentinel)
    }

    @Test @MainActor func displayClipboardRejectsOversizedFlagWithoutBody() {
        let session = DisplaySession()
        session.handleMessage(["type": "clipboard", "text": "tiny", "oversized": true])
        #expect(session.guestClipboard.isEmpty)
        #expect(session.clipboardHint == "Guest clipboard is too large")
    }

    @Test @MainActor func displayClipboardAcceptsMaxSizedGuestPayload() {
        let session = DisplaySession()
        let text = String(repeating: "b", count: HostPasteboard.maxPasteCharacters)
        session.handleMessage(["type": "clipboard", "text": text])
        #expect(session.guestClipboard.count == HostPasteboard.maxPasteCharacters)
        #expect(session.clipboardHint == "Guest copy ready — use Copy")
    }

    @Test @MainActor func displayPasteUsesStructuredQueueNotScriptInterpolation() {
        let session = DisplaySession()
        session.handleMessage(["type": "connect", "width": 800, "height": 600])
        HostPasteboard.writeString("line 1\nquote ' \" emoji 🙂")
        session.pasteFromHost()
        #expect(session.pendingScript == nil)
        #expect(session.pendingPaste == "line 1\nquote ' \" emoji 🙂")
        #expect(session.clipboardHint == "Pasted into guest")
        #expect(session.consumePendingPaste() == nil)
        session.pageReady = true
        #expect(session.consumePendingPaste() == "line 1\nquote ' \" emoji 🙂")
        #expect(session.pendingPaste == nil)
    }

    @Test @MainActor func displayPasteEmptyClipboardIsHint() {
        let session = DisplaySession()
        session.handleMessage(["type": "connect", "width": 800, "height": 600])
        HostPasteboard.clear()
        session.pasteFromHost()
        #expect(session.pendingPaste == nil)
        #expect(session.clipboardHint == "Clipboard is empty")
    }

    @Test @MainActor func hostPasteboardRoundTrip() {
        let token = "pas-220-\(UUID().uuidString)"
        HostPasteboard.writeString(token)
        #expect(HostPasteboard.readString() == token)
        #expect(HostPasteboard.readData() == Data(token.utf8))
    }
}
