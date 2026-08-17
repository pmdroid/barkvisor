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
