import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct DeviceTerminalControllerTests {
    @Test(arguments: [
        (false, true, true, true, DeviceTerminalController.Decision.Status.rejectUnauthorized),
        (true, false, true, true, DeviceTerminalController.Decision.Status.rejectForbidden),
        (true, true, false, true, DeviceTerminalController.Decision.Status.rejectNotImplemented),
        (true, true, true, false, DeviceTerminalController.Decision.Status.rejectBadRequest),
        (true, true, true, true, DeviceTerminalController.Decision.Status.accept),
    ])
    func `gate order: ticket, role, platform, account`(
        _ ticketValid: Bool,
        _ isAdmin: Bool,
        _ platformSupported: Bool,
        _ accountAllowed: Bool,
        _ expected: DeviceTerminalController.Decision.Status,
    ) {
        let decision = DeviceTerminalController.decide(
            ticketValid: ticketValid,
            isAdmin: isAdmin,
            platformSupported: platformSupported,
            accountAllowed: accountAllowed,
        )
        #expect(decision.status == expected)
    }

    @Test func `gate abort statuses map to http codes`() {
        #expect(DeviceTerminalController.Decision(status: .rejectUnauthorized).webSocketAbort == .unauthorized)
        #expect(DeviceTerminalController.Decision(status: .rejectForbidden).webSocketAbort == .forbidden)
        #expect(DeviceTerminalController.Decision(status: .rejectBadRequest).webSocketAbort == .badRequest)
        #expect(DeviceTerminalController.Decision(status: .rejectNotImplemented).webSocketAbort == .notImplemented)
        #expect(DeviceTerminalController.Decision(status: .accept).webSocketAbort == nil)
    }

    #if !os(Windows)
        @Test func `device shell session rejects root and unknown names before spawn`() throws {
            let session = DeviceShellSession()
            #expect(throws: BarkVisorError.self) {
                try session.start(
                    DeviceShellRequest(account: "root"),
                    euid: 0,
                    platform: .macOS,
                    onData: { _ in },
                    onExit: { _ in },
                )
            }
            #expect(throws: BarkVisorError.self) {
                try session.start(
                    DeviceShellRequest(account: "-flag"),
                    onData: { _ in },
                    onExit: { _ in },
                )
            }
        }

        @Test func `device shell as this user echoes until terminate`() async throws {
            let name = NSUserName()
            guard DeviceLoginAccount.spawnRecord(name: name) != nil else { return }
            guard FileManager.default.isExecutableFile(atPath: "/bin/zsh")
                || FileManager.default.isExecutableFile(atPath: "/bin/sh")
            else { return }
            let session = DeviceShellSession()
            let box = PTYTestBox()
            try session.start(
                DeviceShellRequest(account: name),
                onData: { box.appendData($0) },
                onExit: { box.setExit($0) },
            )
            #expect(session.currentState == .running)
            try await Task.sleep(for: .milliseconds(500))
            #expect(box.exit == nil, "login shell must stay alive, exited \(String(describing: box.exit))")
            session.write(Array("printf READY\\n\n".utf8))
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if PTYTestBox.contains(box.bytes, Array("READY".utf8)) { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(
                PTYTestBox.contains(box.bytes, Array("READY".utf8)),
                "shell output: \(box.bytes.count) bytes",
            )
            session.terminate()
            await box.waitUntilExit(timeoutSec: 10)
            #expect(session.currentState == .exited)
        }
    #endif
}

struct DeviceTerminalTicketTests {
    @Test func `device ticket spends on matching host and user`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(
            forUserID: "u1",
            username: "admin",
            targetHostID: "host-1",
            osUser: "pascal",
        )
        let spent = await store.validateTicket(ticket, hostID: "host-1")
        #expect(spent?.osUser == "pascal")
        #expect(spent?.userID == "u1")
        #expect(await store.validateTicket(ticket, hostID: "host-1") == nil)
    }

    @Test func `device ticket cannot open a workload terminal`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(
            forUserID: "u1",
            username: "admin",
            targetHostID: "host-1",
            osUser: "pascal",
        )
        #expect(await store.validateTicket(ticket, forVMID: "vm-1") == nil)
        #expect(await store.validateTicket(ticket) == nil)
        #expect(await store.validateTicket(ticket, hostID: "host-1") == nil)
    }

    @Test func `workload ticket cannot open a device terminal`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(
            forUserID: "u1", username: "admin", targetVMID: "vm-1",
        )
        #expect(await store.validateTicket(ticket, hostID: "host-1") == nil)
        #expect(await store.validateTicket(ticket, forVMID: "vm-1") == nil)
    }

    @Test func `sse ticket cannot open a device terminal`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")
        #expect(await store.validateTicket(ticket, hostID: "host-1") == nil)
        #expect(await store.validateTicket(ticket) == nil)
    }

    @Test func `device ticket rejects a different host`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(
            forUserID: "u1",
            username: "admin",
            targetHostID: "host-1",
            osUser: "pascal",
        )
        #expect(await store.validateTicket(ticket, hostID: "host-2") == nil)
        #expect(await store.validateTicket(ticket, hostID: "host-1") == nil)
    }
}
