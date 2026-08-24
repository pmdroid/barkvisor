import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct CodingAgentSessionTests {
    @Test func `start requires coding image and agent cage`() throws {
        let grant = "barkvisor_home_grant"
        let plan = try CodingAgentSession.start(
            vmID: "vm-coder",
            isCodingImage: true,
            workloadClass: .agent,
            grantPlaintext: grant,
            terminalHostPort: 7_681,
        )
        #expect(plan.grant == "home-ollama")
        #expect(plan.openaiBaseURL == CodingAgentImage.homeOllamaGrantURL)
        #expect(plan.openaiBaseURL.contains("10.0.2.2:11434"))
        #expect(plan.openaiAPIKey == grant)
        #expect(plan.surfaces == ["chat", "terminal"])
        #expect(throws: BarkVisorError.self) {
            try CodingAgentSession.start(
                vmID: "vm-coder",
                isCodingImage: false,
                workloadClass: .agent,
                grantPlaintext: grant,
                terminalHostPort: 7_681,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentSession.start(
                vmID: "vm-coder",
                isCodingImage: true,
                workloadClass: .house,
                grantPlaintext: grant,
                terminalHostPort: 7_681,
            )
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentSession.start(
                vmID: "vm-coder",
                isCodingImage: true,
                workloadClass: .agent,
                grantPlaintext: "  ",
                terminalHostPort: 7_681,
            )
        }
    }

    @Test func `proxy is home chat and serial terminal`() throws {
        let plan = try CodingAgentSession.start(
            vmID: "vm-coder",
            isCodingImage: true,
            workloadClass: .agent,
            grantPlaintext: "k",
            terminalHostPort: 17_681,
        )
        #expect(plan.chatPath == "/v1/chat/completions")
        #expect(plan.terminalPath == "/api/vms/vm-coder/console")
        #expect(CodingAgentSession.chatPath == plan.chatPath)
        #expect(CodingAgentSession.terminalPath(vmID: "vm-coder") == plan.terminalPath)
        #expect(plan.webTerminalGuestPort == 7_681)
        #expect(plan.webTerminalHostPort == 17_681)
        #expect(plan.loopbackHostfwd == "hostfwd=tcp:127.0.0.1:17681-:7681")
        #expect(!plan.loopbackHostfwd.contains("::"))
    }

    @Test func `env is OPENAI_BASE_URL to the Home Ollama grant`() throws {
        let plan = try CodingAgentSession.start(
            vmID: "vm-coder",
            isCodingImage: true,
            workloadClass: .agent,
            openaiBaseURL: nil,
            grantPlaintext: "barkvisor_abc",
            terminalHostPort: 7_681,
        )
        let env = CodingAgentSession.env(plan)
        #expect(env["OPENAI_BASE_URL"] == CodingAgentImage.homeOllamaGrantURL)
        #expect(env["OPENAI_API_KEY"] == "barkvisor_abc")
        #expect(
            CodingAgentSession.env(
                openaiBaseURL: "https://api.example/v1",
                grantPlaintext: "sk-byo",
            ) == [
                "OPENAI_BASE_URL": "https://api.example/v1",
                "OPENAI_API_KEY": "sk-byo",
            ],
        )
        let yaml = CodingAgentImage.userData(openaiBaseURL: CodingAgentImage.homeOllamaGrantURL)
        #expect(CodingAgentSession.wantsWebTerminal(userData: yaml))
        #expect(CodingAgentSession.usesHomeOllamaGrant(userData: yaml))
        #expect(!CodingAgentSession.wantsWebTerminal(userData: "packages:\n  - vim\n"))
        #expect(!CodingAgentSession.usesHomeOllamaGrant(userData: nil))
    }

    @Test func `agent NAT loopback hostfwd is not a published port forward`() throws {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "coder"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: 1, memoryMb: 512),
                networks: [WorkloadNetwork(mode: "nat")],
                workloadClass: "agent",
            ),
        )
        let fwd = QEMULoopbackForward(hostPort: 17_681, guestPort: 7_681)
        let (args, _) = try QEMUBuilder.networkArgs(
            spec: spec,
            network: nil,
            allowHostOllama: true,
            loopbackHostfwds: [fwd],
        )
        let netdev = args.first { $0.hasPrefix("user,id=net0") }
        #expect(netdev?.contains("hostfwd=tcp:127.0.0.1:17681-:7681") == true)
        #expect(netdev?.contains("hostfwd=tcp::") != true)
        #expect(netdev?.contains("11434") == true)
        #expect(spec.spec.networks.first?.portForwards.isEmpty == true)
    }

    @Test func `session store drops the ttyd host port on remove`() async {
        let store = CodingAgentSessionStore()
        await store.record(vmID: "vm-coder", terminalHostPort: 17_681)
        await store.record(vmID: "vm-other", terminalHostPort: 17_682)
        #expect(await store.port(for: "vm-coder") == 17_681)
        let occupied = await store.occupiedHostPorts()
        #expect(Set(occupied) == [17_681, 17_682])
        await store.remove(vmID: "vm-coder")
        #expect(await store.port(for: "vm-coder") == nil)
        #expect(await store.occupiedHostPorts() == [17_682])
        await store.remove(vmID: "vm-coder")
        #expect(await store.occupiedHostPorts() == [17_682])
    }

    @Test func `handleTermination and stopAll drop the ttyd host port`() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let manager = VMManager(dbPool: pool)
        let store = CodingAgentSessionStore.shared

        let crashID = "vm-coder-crash-\(UUID().uuidString)"
        await manager.registerReconnectedVM(
            vmID: crashID,
            running: Self.deadRunningVM(),
            codingAgentHostPort: 17_681,
        )
        #expect(await store.port(for: crashID) == 17_681)
        await manager.handleTermination(vmID: crashID, status: 1)
        #expect(await store.port(for: crashID) == nil)
        let afterCrash = await store.occupiedHostPorts()
        #expect(!Set(afterCrash).contains(17_681))

        let stopID = "vm-coder-stopall-\(UUID().uuidString)"
        await manager.registerReconnectedVM(
            vmID: stopID,
            running: Self.deadRunningVM(),
            codingAgentHostPort: 17_690,
        )
        #expect(await store.port(for: stopID) == 17_690)
        await manager.stopAll()
        #expect(await store.port(for: stopID) == nil)
        let afterStopAll = await store.occupiedHostPorts()
        #expect(!Set(afterStopAll).contains(17_690))
    }

    private static func deadRunningVM() -> RunningVM {
        RunningVM(
            process: nil,
            pid: 2_000_000_001,
            serialSocketPath: "/tmp/barkvisor-none.serial",
            vncSocketPath: "/tmp/barkvisor-none.vnc",
            qmpSocketPath: "/tmp/barkvisor-none.qmp",
            qmpEventSocketPath: "/tmp/barkvisor-none.event",
            swtpmProcess: nil,
            reconnected: true,
        )
    }

    @Test func `loopback host port is parsed from QEMU netdev`() {
        let netdev =
            "user,id=net0,hostfwd=tcp::8080-:80,hostfwd=tcp:127.0.0.1:17681-:7681"
        #expect(
            CodingAgentSession.loopbackHostPort(fromQEMUArguments: ["-netdev", netdev]) == 17_681,
        )
        #expect(
            CodingAgentSession.loopbackHostPort(
                fromQEMUArguments: [CodingAgentSession.loopbackHostfwd(hostPort: 9_001)],
            ) == 9_001,
        )
        #expect(CodingAgentSession.loopbackHostPort(fromQEMUArguments: ["-netdev", "user,id=net0"]) == nil)
        #expect(
            CodingAgentSession.loopbackHostPort(
                fromQEMUArguments: ["hostfwd=tcp:127.0.0.1:17681-:22"],
            ) == nil,
        )
    }

    @Test func `recovered ttyd host port prefers QEMU argv over pid file`() {
        let netdev = "user,id=net0,\(CodingAgentSession.loopbackHostfwd(hostPort: 17_681))"
        #expect(
            CodingAgentSession.recoveredTerminalHostPort(
                qemuArguments: ["-netdev", netdev],
                pidFilePort: 9_001,
            ) == 17_681,
        )
        #expect(
            CodingAgentSession.recoveredTerminalHostPort(
                qemuArguments: nil,
                pidFilePort: 9_001,
            ) == 9_001,
        )
        #expect(
            CodingAgentSession.recoveredTerminalHostPort(
                qemuArguments: ["-netdev", "user,id=net0"],
                pidFilePort: nil,
            ) == nil,
        )
    }
}
