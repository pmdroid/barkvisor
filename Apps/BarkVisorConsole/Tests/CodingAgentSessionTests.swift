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
        #expect(CodingAgentSession.noPushCopy == "NO PUSH")
        #expect(CodingAgentSession.expiryAction == "stop")
        #expect(CodingAgentSession.warningLeadSeconds == 15 * 60)
        #expect(
            CodingAgentSession.env(grantPlaintext: "barkvisor_abc") == [
                "OPENAI_BASE_URL": CodingAgentImage.homeOllamaGrantURL,
                "OPENAI_API_KEY": "barkvisor_abc",
            ],
        )
    }

    @Test func `session receipt is NO PUSH when git is missing`() throws {
        let json = """
        {
          "ttlSeconds": 14400,
          "warning": true,
          "warningLeadSeconds": 900,
          "expiryAction": "stop",
          "grant": "home-ollama",
          "actions": ["resume", "reset", "burn"],
          "receipt": {
            "stoppedAt": "2026-08-23T12:00:00Z",
            "reason": "ttl",
            "lastGitPushAt": null,
            "noPush": true
          }
        }
        """.data(using: .utf8)!
        let session = try JSONDecoder().decode(CodingAgentSessionInfo.self, from: json)
        #expect(session.expiryAction == CodingAgentSession.expiryAction)
        #expect(session.receiptLine(vmState: "stopped")?.loud == true)
        #expect(session.receiptLine(vmState: "stopped")?.git == CodingAgentSession.noPushCopy)
        #expect(session.receiptLine(vmState: "running") == nil)
        #expect(session.receiptLine(vmState: "stopping") == nil)
        #expect(
            CodingAgentSession.warningCopy(remainingSeconds: 15 * 60)
                == "Session expires in 15 minutes. Push your changes. TTL stop keeps the disk.",
        )
        #expect(
            CodingAgentSession.warningCopy(remainingSeconds: 60)
                == "Session expires in 1 minute. Push your changes. TTL stop keeps the disk.",
        )
    }
}
