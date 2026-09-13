import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Issue #609 — app workload terminal: gate table, exec-target resolution,
/// control frames, exec session lifecycle, and PTY round-trip/reap.
struct TerminalControllerTests {
    // MARK: - Gate table

    @Test(arguments: [
        // ticketValid, isAdmin, exists, isApp, serviceOK, running, expected
        (false, true, true, true, true, true, TerminalController.Decision.Status.rejectUnauthorized),
        (true, false, true, true, true, true, TerminalController.Decision.Status.rejectForbidden),
        (true, true, false, false, true, false, TerminalController.Decision.Status.rejectNotFound),
        (true, true, true, false, true, true, TerminalController.Decision.Status.rejectNotFound),
        (true, true, true, true, false, true, TerminalController.Decision.Status.rejectBadRequest),
        (true, true, true, true, true, false, TerminalController.Decision.Status.closeNotRunning),
        (true, true, true, true, true, true, TerminalController.Decision.Status.accept),
    ])
    func `gate order: ticket, role, kind, service, running`(
        _ ticketValid: Bool,
        _ isAdmin: Bool,
        _ exists: Bool,
        _ isApp: Bool,
        _ serviceOK: Bool,
        _ running: Bool,
        _ expected: TerminalController.Decision.Status,
    ) {
        let decision = TerminalController.decide(
            ticketValid: ticketValid,
            isAdmin: isAdmin,
            workloadExists: exists,
            isApplication: isApp,
            serviceValid: serviceOK,
            isRunning: running,
        )
        #expect(decision.status == expected)
    }

    @Test func `gate abort statuses map to issue status codes`() {
        #expect(TerminalController.Decision(status: .rejectUnauthorized).webSocketAbort == .unauthorized)
        #expect(TerminalController.Decision(status: .rejectForbidden).webSocketAbort == .forbidden)
        #expect(TerminalController.Decision(status: .rejectNotFound).webSocketAbort == .notFound)
        #expect(TerminalController.Decision(status: .rejectBadRequest).webSocketAbort == .badRequest)
        // Stopped apps do not abort the upgrade: clean text-frame close (serve).
        #expect(TerminalController.Decision(status: .closeNotRunning).webSocketAbort == nil)
        #expect(TerminalController.Decision(status: .accept).webSocketAbort == nil)
    }

    @Test func `requestedService reads service query item`() {
        #expect(
            TerminalController.requestedService(inQuery: "ticket=t&service=web&rows=24") == "web",
        )
        #expect(TerminalController.requestedService(inQuery: "ticket=t") == nil)
        #expect(TerminalController.requestedService(inQuery: nil) == nil)
    }

    // MARK: - Resize control frames

    @Test func `resize control frame parsing`() {
        #expect(
            DockerExecControl.decodeResize(#"{"type":"resize","cols":120,"rows":32}"#)
                == DockerExecControl.Resize(cols: 120, rows: 32),
        )
        #expect(
            DockerExecControl.decodeResize(#"{"type":"resize","cols":"100","rows":30.0}"#)
                == DockerExecControl.Resize(cols: 100, rows: 30),
        )
        // Missing both dimensions, wrong type, and garbage are all ignored
        // (forward-compatible control channel).
        #expect(DockerExecControl.decodeResize(#"{"type":"resize"}"#) == nil)
        #expect(DockerExecControl.decodeResize(#"{"type":"ping"}"#) == nil)
        #expect(DockerExecControl.decodeResize("not json") == nil)
        #expect(DockerExecControl.decodeResize("") == nil)
    }

    // MARK: - Compose ps decoding + project-scoped resolution

    @Test func `compose ps decodes array, single object, and ndjson`() {
        let array = #"""
        [{"ID":"aa","Name":"bv-web-1","Image":"nginx","Service":"web","State":"running"},
         {"ID":"bb","Name":"bv-db-1","Image":"postgres","Service":"db","State":"running"}]
        """#
        let decoded = ContainerResolver.decodeComposePS(array)
        #expect(decoded.count == 2)
        #expect(decoded[0].service == "web")
        #expect(decoded[0].name == "bv-web-1")
        #expect(decoded[0].state == "running")

        let single = #"{"Name":"bv-web-1","Service":"web","State":"Exited"}"#
        let one = ContainerResolver.decodeComposePS(single)
        #expect(one == [WorkloadContainer(service: "web", name: "bv-web-1", state: "exited")])

        let ndjson = """
        {"Name":"a-1","Service":"a","State":"running"}
        {"Name":"b-1","Service":"b","State":"restarting"}
        """
        let two = ContainerResolver.decodeComposePS(ndjson)
        #expect(two.map(\.service) == ["a", "b"])
        #expect(two[1].state == "restarting")

        #expect(ContainerResolver.decodeComposePS("") == [])
        #expect(ContainerResolver.decodeComposePS("not json at all") == [])
        // Rows without Service/Name are docker metadata noise, dropped.
        #expect(ContainerResolver.decodeComposePS(#"{"ID":"aa","Image":"x"}"#) == [])
    }

    @Test func `resolve only matches services inside the workload project`() throws {
        let containers = [
            WorkloadContainer(service: "web", name: "bv-web-1", state: "running"),
            WorkloadContainer(service: "db", name: "bv-db-1", state: "running"),
        ]
        #expect(try ContainerResolver.resolve(containers: containers, service: "db").name == "bv-db-1")
        // Arbitrary/foreign names can never be exec'd — the project list is
        // the allowlist.
        #expect(throws: BarkVisorError.self) {
            _ = try ContainerResolver.resolve(containers: containers, service: "sidecar")
        }
        #expect(throws: BarkVisorError.self) {
            _ = try ContainerResolver.resolve(containers: containers, service: "")
        }
        #expect(throws: BarkVisorError.self) {
            _ = try ContainerResolver.resolve(containers: containers, service: "../evil")
        }
    }

    @Test(arguments: ["web", "api_v2", "svc-1", "Web1"])
    func `valid service names`(_ name: String) {
        #expect(ContainerResolver.isValidServiceName(name))
    }

    @Test(arguments: ["", "-lead", "a b", "a/b", "a;b", "a|b", "$x", "a.b\nc", String(repeating: "s", count: 200)])
    func `invalid service names are rejected`(_ name: String) {
        #expect(!ContainerResolver.isValidServiceName(name))
    }

    @Test(arguments: ["bv-web-1", "barkvisor-abc.1"])
    func `valid exec target names`(_ name: String) {
        #expect(DockerExecRequest.isSafeExecutableName(name))
    }

    @Test(arguments: ["", "-it", "a b", "$(rm)", "a;b", "/abs/path", ".."])
    func `unsafe exec target names are rejected`(_ name: String) {
        #expect(!DockerExecRequest.isSafeExecutableName(name))
    }

    @Test func `exec arguments pin exec -it container shell`() {
        #expect(
            DockerExecSession.execArguments(container: "bv-web-1", shell: "sh")
                == ["exec", "-it", "bv-web-1", "sh"],
        )
        #expect(DockerExecSession.execArguments(container: "-v /:/host", shell: "sh") == nil)
        #expect(DockerExecSession.execArguments(container: "c", shell: "sh; rm -rf /") == nil)
    }

    // MARK: - Exec session lifecycle (fake launcher, no docker)

    private final class FakeExecChild: ExecPTYHandling, @unchecked Sendable {
        private let lock = NSLock()
        private var _writes: [[UInt8]] = []
        private var _resizes: [(cols: Int, rows: Int)] = []
        private var _terminated = false
        var launchExecutable = ""
        var launchArguments: [String] = []
        var onData: (@Sendable ([UInt8]) -> Void)?
        var onExit: (@Sendable (Int32) -> Void)?

        func write(_ bytes: [UInt8]) {
            lock.lock()
            _writes.append(bytes)
            lock.unlock()
        }

        func resize(cols: Int, rows: Int) {
            lock.lock()
            _resizes.append((cols, rows))
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            _terminated = true
            lock.unlock()
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return !_terminated
        }

        var writes: [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            return _writes
        }

        var resizes: [(cols: Int, rows: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return _resizes
        }

        var terminated: Bool {
            lock.lock()
            defer { lock.unlock() }
            return _terminated
        }

        func emit(_ bytes: [UInt8]) {
            lock.lock()
            let handler = onData
            lock.unlock()
            handler?(bytes)
        }

        func emitExit(_ code: Int32) {
            lock.lock()
            let handler = onExit
            lock.unlock()
            handler?(code)
        }
    }

    private struct FakeLauncher: ExecPTYLaunching {
        let child: FakeExecChild
        func launch(
            executable: String,
            arguments: [String],
            onData: @escaping @Sendable ([UInt8]) -> Void,
            onExit: @escaping @Sendable (Int32) -> Void,
        ) throws -> any ExecPTYHandling {
            child.launchExecutable = executable
            child.launchArguments = arguments
            child.onData = onData
            child.onExit = onExit
            return child
        }
    }

    @Test func `exec session spawns exec -it and forwards io resize exit once`() throws {
        let child = FakeExecChild()
        let session = try DockerExecSession(launcher: FakeLauncher(child: child), dockerExecutable: "/usr/bin/docker")
        let seen = PTYTestBox()

        try session.start(
            DockerExecRequest(container: "bv-web-1", shell: "sh", cols: 100, rows: 30),
            onData: { seen.appendData($0) },
            onExit: { seen.setExit($0) },
        )
        #expect(child.launchExecutable == "/usr/bin/docker")
        #expect(child.launchArguments == ["exec", "-it", "bv-web-1", "sh"])
        #expect(child.resizes.first?.cols == 100)
        #expect(child.resizes.first?.rows == 30)
        #expect(session.currentState == .running)

        child.emit(Array("prompt$ ".utf8))
        session.write(Array("ls\n".utf8))
        #expect(child.writes.count == 1)
        #expect(child.writes[0] == Array("ls\n".utf8))
        #expect(seen.bytes == Array("prompt$ ".utf8))

        child.emitExit(3)
        child.emitExit(3) // reaper races must not double-report
        #expect(seen.exit == 3)
        #expect(session.lastExitCode == 3)
        #expect(session.currentState == .exited)

        session.terminate()
        #expect(child.terminated)

        // A second start on the same session is a programming error, not a respawn.
        #expect(throws: BarkVisorError.self) {
            try session.start(
                DockerExecRequest(container: "bv-web-1"),
                onData: { _ in },
                onExit: { _ in },
            )
        }
    }

    @Test func `exec session rejects unsafe targets before spawn`() throws {
        let child = FakeExecChild()
        let session = try DockerExecSession(launcher: FakeLauncher(child: child), dockerExecutable: "/usr/bin/docker")
        #expect(throws: BarkVisorError.self) {
            try session.start(
                DockerExecRequest(container: "--privileged -v /:/host x", shell: "sh"),
                onData: { _ in },
                onExit: { _ in },
            )
        }
        #expect(child.launchArguments.isEmpty)
    }

    // MARK: - Real PTY round-trip (skips where /bin/sh is absent)

    @Test func `pty round-trip echo resize and reap exit code`() async throws {
        let shell = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let pty = PTYProcess()
        let box = PTYTestBox()
        pty.configure(onData: { box.appendData($0) }, onExit: { box.setExit($0) })
        try pty.start(
            executable: shell,
            arguments: ["-c", "printf READY; exit 7"],
        )
        pty.resize(cols: 100, rows: 30)
        await box.waitUntilExit(timeoutSec: 10)
        #expect(
            PTYTestBox.contains(box.bytes, Array("READY".utf8)),
            "pty output reached onData: \(box.bytes.count) bytes",
        )
        #expect(box.exit == 7, "exit code 7 was reaped, got \(String(describing: box.exit))")
        #expect(!pty.isRunning)
        pty.write(Array("late\n".utf8)) // after exit: must not crash
        pty.terminate() // idempotent post-mortem
    }

    @Test func `pty terminate kills and reaps the child`() async throws {
        let shell = "/bin/sh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return }
        let pty = PTYProcess()
        let box = PTYTestBox()
        pty.configure(onData: { box.appendData($0) }, onExit: { box.setExit($0) })
        try pty.start(executable: shell, arguments: ["-c", "sleep 30"])
        #expect(pty.isRunning)
        pty.terminate()
        await box.waitUntilExit(timeoutSec: 10)
        #expect(box.exit == 137, "SIGKILL reaps as 128+9, got \(String(describing: box.exit))")
        #expect(!pty.isRunning)
    }
}

/// Lock-guarded capture for PTY callbacks arriving off-thread.
final class PTYTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: [UInt8] = []
    private var code: Int32?

    func appendData(_ data: [UInt8]) {
        lock.lock()
        _bytes.append(contentsOf: data)
        lock.unlock()
    }

    func setExit(_ code: Int32) {
        lock.lock()
        self.code = code
        lock.unlock()
    }

    var bytes: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return self._bytes
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for i in 0 ... (haystack.count - needle.count) {
            if Array(haystack[i ..< i + needle.count]) == needle { return true }
        }
        return false
    }

    var exit: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return code
    }

    func waitUntilExit(timeoutSec: Double) async {
        var waited = 0.0
        while exit == nil, waited < timeoutSec {
            try? await Task.sleep(nanoseconds: 25_000_000)
            waited += 0.025
        }
        // Give the read side one beat past exit (EOF ordering is exit-after-EOF,
        // but the reaper can win the race on fast exits).
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
}
