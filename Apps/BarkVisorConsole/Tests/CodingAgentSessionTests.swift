import Foundation
import Testing
@testable import BarkVisorConsole

struct CodingAgentSessionTests {
    @Test func `start needs coding image and agent cage`() {
        #expect(CodingAgentSession.isSession(workloadClass: "agent"))
        #expect(!CodingAgentSession.isSession(workloadClass: "house"))
        #expect(CodingAgentSession.surfaces(workloadClass: "agent") == ["chat", "terminal"])
        #expect(CodingAgentSession.surfaces(workloadClass: "house").isEmpty)
    }

    @Test func `proxy is home chat and serial terminal`() {
        #expect(CodingAgentSession.grant == "home-ollama")
        #expect(CodingAgentSession.chatPath == "/v1/chat/completions")
        #expect(CodingAgentSession.terminalPath(vmID: "vm-1") == "/api/vms/vm-1/console")
        #expect(CodingAgentSession.consoleTitle(isSession: true) == "Terminal")
        #expect(CodingAgentSession.consoleTitle(isSession: false) == "Console")
    }

    @Test func `env is OPENAI_BASE_URL to the Home Ollama grant`() {
        #expect(CodingAgentImage.homeOllamaGrantURL == "http://10.0.2.2:11434/v1")
        #expect(
            CodingAgentSession.env(grantPlaintext: "barkvisor_abc") == [
                "OPENAI_BASE_URL": CodingAgentImage.homeOllamaGrantURL,
                "OPENAI_API_KEY": "barkvisor_abc",
            ],
        )
    }
}
