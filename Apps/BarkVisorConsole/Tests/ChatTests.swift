import Foundation
import Testing
@testable import BarkVisorConsole

struct ChatTests {
    private let decoder = JSONDecoder()

    @Test func `catalog decodes and hides chat without models`() throws {
        let json = """
        {
          "anyReachable": true,
          "anyInstalled": true,
          "models": [
            {
              "name": "llama3:latest",
              "running": true,
              "locations": [
                {
                  "hostId": "desk",
                  "displayName": "desk",
                  "running": true,
                  "reachable": true,
                  "probedAt": "2026-08-22T00:00:00Z"
                }
              ]
            }
          ],
          "devices": [
            {
              "hostId": "desk",
              "displayName": "desk",
              "installed": true,
              "reachable": true,
              "stale": false,
              "installHint": "brew install ollama"
            }
          ]
        }
        """.data(using: .utf8)!

        let catalog = try decoder.decode(OllamaHomeCatalog.self, from: json)
        #expect(ChatAvailability.visible(catalog: catalog))
        #expect(ChatAvailability.defaultModel(in: catalog) == "llama3:latest")
        #expect(!ChatAvailability.visible(anyReachable: true, modelCount: 0))
        #expect(!ChatAvailability.visible(catalog: nil))
        #expect(AppRoute.chat.title == "Chat")
        #expect(AppRoute.chat.symbol == "bubble.left.and.bubble.right")
        #expect(PhoneTab.chat.rawValue == "chat")
    }

    @Test func `sse drains open AI token lines`() {
        var buffer =
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hel\"}}]}\n" +
            "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n" +
            "data: [DONE]\npartial"
        let deltas = ChatSSE.drain(buffer: &buffer)
        #expect(deltas == ["Hel", "lo"])
        #expect(buffer == "partial")
        #expect(ChatSSE.content(fromLine: "data: {\"choices\":[{\"message\":{\"content\":\"full\"}}]}") == "full")
        #expect(ChatSSE.content(fromLine: ": keepalive") == nil)
    }

    @Test func `chat post body streams true`() throws {
        let body = ChatCompletionBody(
            model: "llama3:latest",
            stream: true,
            messages: [ChatWireMessage(role: "user", content: "hi")],
        )
        let data = try JSONEncoder().encode(body)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["stream"] as? Bool == true)
        #expect(object?["model"] as? String == "llama3:latest")
        #expect(APIClient.chatCompletionsPath == "/v1/chat/completions")
    }
}
