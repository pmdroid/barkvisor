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
        #expect(ChatAvailability.defaultModel(in: nil).isEmpty)
        #expect(AppRoute.chat.title == "Chat")
        #expect(AppRoute.chat.symbol == "bubble.left.and.bubble.right")
        #expect(PhoneTab.chat.rawValue == "chat")
    }

    @Test func `stale deltas stay on the originating assistant turn`() {
        let first = ChatTurn(role: "assistant", content: "")
        let second = ChatTurn(role: "assistant", content: "")
        var turns = [
            ChatTurn(role: "user", content: "one"),
            first,
            ChatTurn(role: "user", content: "two"),
            second,
        ]
        ChatStreamApply.append(
            delta: "stale",
            to: &turns,
            assistantID: first.id,
            generation: 1,
            currentGeneration: 2,
        )
        #expect(turns[1].content.isEmpty)
        #expect(turns[3].content.isEmpty)
        ChatStreamApply.append(
            delta: "ok",
            to: &turns,
            assistantID: second.id,
            generation: 2,
            currentGeneration: 2,
        )
        #expect(turns[1].content.isEmpty)
        #expect(turns[3].content == "ok")
        ChatStreamApply.append(
            delta: "late",
            to: &turns,
            assistantID: first.id,
            generation: 1,
            currentGeneration: 2,
        )
        #expect(turns[1].content.isEmpty)
        #expect(turns[3].content == "ok")
    }

    @Test func `stale send errors do not roll back a newer turn`() {
        let first = ChatTurn(role: "assistant", content: "")
        let second = ChatTurn(role: "assistant", content: "ok")
        var turns = [
            ChatTurn(role: "user", content: "one"),
            first,
            ChatTurn(role: "user", content: "two"),
            second,
        ]
        var draft = ""
        ChatStreamApply.rollbackFailedSend(
            turns: &turns,
            draft: &draft,
            originalText: "one",
            assistantID: first.id,
            generation: 1,
            currentGeneration: 2,
        )
        #expect(turns.count == 4)
        #expect(turns[3].content == "ok")
        #expect(draft.isEmpty)
        ChatStreamApply.rollbackFailedSend(
            turns: &turns,
            draft: &draft,
            originalText: "one",
            assistantID: first.id,
            generation: 2,
            currentGeneration: 2,
        )
        #expect(turns.map(\.content) == ["two", "ok"])
        #expect(draft == "one")
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

    @Test func `chat stream retries once after 401 with a refreshed token`() async throws {
        var client = try APIClient(
            baseURL: #require(URL(string: "http://127.0.0.1:7777")),
            token: "old",
        )
        client.refreshOnce = { .rotated("new") }
        var request = try URLRequest(url: #require(URL(string: "http://127.0.0.1:7777/v1/chat/completions")))
        request.setValue("Bearer old", forHTTPHeaderField: "Authorization")
        let retry = try await client.retryAfter401(request, status: 401, allowRefresh: true)
        #expect(retry?.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        do {
            _ = try await client.retryAfter401(request, status: 401, allowRefresh: false)
            Issue.record("expected unauthorized when refresh is already spent")
        } catch {
            #expect(error as? APIError == .unauthorized)
        }
        let unchanged = try await client.retryAfter401(request, status: 200, allowRefresh: true)
        #expect(unchanged?.value(forHTTPHeaderField: "Authorization") == nil)
    }
}
