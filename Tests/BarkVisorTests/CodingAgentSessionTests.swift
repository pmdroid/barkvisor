import Foundation
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
        #expect(await store.port(for: "vm-coder") == 17_681)
        #expect(await store.occupiedHostPorts() == [17_681])
        await store.remove(vmID: "vm-coder")
        #expect(await store.port(for: "vm-coder") == nil)
        #expect(await store.occupiedHostPorts().isEmpty)
    }
}
