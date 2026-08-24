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

    @Test func `ios chat webview loads home chat route without jwt in the query`() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImV4cCI6OTk5OTk5OTk5OX0.sig"
        let origin = try DeviceURL.normalize("http://192.168.30.1:7777/dashboard?token=\(jwt)")
        let url = try ChatWebSession.pageURL(home: origin)
        #expect(url.scheme == "http")
        #expect(url.host == "192.168.30.1")
        #expect(url.port == 7_777)
        #expect(url.path == ChatWebSession.routePath)
        #expect(url.path == "/chat")
        #expect(url.query == nil)
        #expect(url.fragment == nil)
        #expect(!url.absoluteString.contains("?"))
        #expect(!ChatWebSession.containsSecret(url, secret: jwt))
        #expect(!url.absoluteString.lowercased().contains("bearer"))

        let sneaky = try #require(URL(string: "http://192.168.30.1:7777/chat?access_token=\(jwt)&jwt=\(jwt)"))
        let stripped = try ChatWebSession.pageURL(home: sneaky)
        #expect(stripped.query == nil)
        #expect(!ChatWebSession.containsSecret(stripped, secret: jwt))

        let ipv6 = try ChatWebSession.pageURL(home: DeviceURL.normalize("http://[fd12:3456:789a::1]:7777"))
        #expect(ipv6.path == "/chat")
        #expect(ipv6.query == nil)
        #expect(ipv6.host == "fd12:3456:789a::1")
    }

    @Test func `ios chat webview injects bearer header cookie and localStorage`() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImV4cCI6OTk5OTk5OTk5OX0.sig"
        let origin = try DeviceURL.normalize("https://home.local:7777")
        let request = try ChatWebSession.pageRequest(home: origin, token: jwt)
        #expect(request.url?.path == "/chat")
        #expect(request.url?.query == nil)
        #expect(try !ChatWebSession.containsSecret(#require(request.url), secret: jwt))
        #expect(
            request.value(forHTTPHeaderField: ChatWebSession.authorizationHeaderName)
                == ChatWebSession.authorizationHeader(token: jwt),
        )
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(jwt)")

        let cookie = try #require(ChatWebSession.cookie(home: origin, token: jwt))
        #expect(cookie.name == ChatWebSession.tokenCookieName)
        #expect(cookie.value == jwt)
        #expect(cookie.path == "/")
        #expect(cookie.isSecure)
        #expect(cookie.isHTTPOnly == false)

        let script = ChatWebSession.userScriptSource(home: origin, token: jwt)
        #expect(script.contains("localStorage.setItem"))
        #expect(script.contains(ChatWebSession.tokenStorageKey))
        #expect(script.contains("document.cookie"))
        #expect(script.contains("Secure"))
        #expect(script.contains("localStorage.removeItem"))
        #expect(script.contains(jwt))
        #expect(script.contains("encodeURIComponent"))
        #expect(!script.contains("?token="))
        #expect(!script.contains("access_token="))

        let quoted = ChatWebSession.userScriptSource(token: "tok\"en\n")
        #expect(quoted.contains(ChatWebSession.jsonString("tok\"en\n")))
        #expect(!quoted.contains("token = tok\"en"))

        let refresh = "bvrt_family"
        let withRefresh = ChatWebSession.userScriptSource(token: jwt, refreshToken: refresh)
        #expect(withRefresh.contains(ChatWebSession.refreshStorageKey))
        #expect(withRefresh.contains(refresh))
        #expect(withRefresh.contains(ChatWebSession.sessionEventName))
        let withoutRefresh = ChatWebSession.userScriptSource(token: jwt, refreshToken: "")
        #expect(withoutRefresh.contains("localStorage.removeItem"))
        #expect(!ChatWebSession.viewIdentity(home: origin).contains(jwt))
        #expect(ChatWebSession.viewIdentity(home: origin).contains("home.local"))

        let inference = "barkvisor_live_secret"
        let keyScript = ChatWebSession.userScriptSource(token: inference)
        #expect(keyScript.contains(inference))
        let keyRequest = try ChatWebSession.pageRequest(home: origin, token: inference)
        #expect(keyRequest.value(forHTTPHeaderField: "Authorization") == "Bearer \(inference)")
        #expect(try !ChatWebSession.containsSecret(#require(keyRequest.url), secret: inference))
    }

    @Test func `ios chat webview identity ignores jwt rotation and blocks secret urls`() throws {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhZG1pbiIsImV4cCI6OTk5OTk5OTk5OX0.sig"
        let refresh = "bvrt_family"
        let origin = try DeviceURL.normalize("http://192.168.30.1:7777")
        let identity = ChatWebSession.viewIdentity(home: origin)
        #expect(identity == ChatWebSession.viewIdentity(home: origin))
        #expect(!identity.contains(jwt))
        #expect(!identity.contains("\u{1e}"))

        let chat = try ChatWebSession.pageURL(home: origin)
        #expect(ChatWebSession.allowsNavigation(chat, home: origin, secrets: [jwt, refresh]))
        #expect(
            try ChatWebSession.allowsNavigation(
                #require(URL(string: "about:blank")),
                home: origin,
                secrets: [jwt],
            ),
        )
        let sneaky = try #require(URL(string: "http://192.168.30.1:7777/chat?access_token=\(jwt)"))
        #expect(!ChatWebSession.allowsNavigation(sneaky, home: origin, secrets: [jwt, refresh]))
        #expect(ChatWebSession.containsSecret(sneaky, secret: jwt))
        let refreshInQuery = try #require(URL(string: "http://192.168.30.1:7777/chat?refresh=\(refresh)"))
        #expect(!ChatWebSession.allowsNavigation(refreshInQuery, home: origin, secrets: [jwt, refresh]))
        let otherOrigin = try #require(URL(string: "https://evil.example/chat"))
        #expect(!ChatWebSession.allowsNavigation(otherOrigin, home: origin, secrets: [jwt]))
        #expect(ChatWebSession.navigationSecrets(token: jwt, refreshToken: refresh) == [jwt, refresh])
        #expect(ChatWebSession.navigationSecrets(token: jwt, refreshToken: "").count == 1)
        #expect(ChatWebSession.parseBridgeMessage(["type": "refresh"]) == .refresh)
        #expect(
            ChatWebSession.parseBridgeMessage(["type": "session", "token": jwt, "refreshToken": refresh])
                == .session(token: jwt, refreshToken: refresh),
        )
        #expect(ChatWebSession.parseBridgeMessage(["type": "session", "token": ""]) == nil)
        #expect(ChatWebSession.shouldAdopt(
            currentToken: jwt,
            currentRefresh: refresh,
            nextToken: "jwt-2",
            nextRefresh: "bvrt_next",
        ))
        #expect(
            !ChatWebSession.shouldAdopt(
                currentToken: jwt,
                currentRefresh: refresh,
                nextToken: jwt,
                nextRefresh: refresh,
            ),
        )
        #expect(
            !ChatWebSession.shouldAdopt(
                currentToken: jwt,
                currentRefresh: refresh,
                nextToken: "jwt-2",
                nextRefresh: "",
            ),
        )
    }

    @Test func `ios chat webview syncs refresh through the native session bridge`() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/ChatView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("ChatWebSession.messageHandlerName"))
        #expect(source.contains("WKScriptMessageHandler"))
        #expect(source.contains("Task { @MainActor"))
        #expect(source.contains("ChatWebSession.navigationSecrets"))
        #expect(source.contains("adoptWebSession"))
        #expect(source.contains("refreshSessionFromWeb"))
        #expect(source.contains("handleBridgeMessage"))
        #expect(ChatWebSession.messageHandlerName == "barkvisorSession")
    }

    @Test func `mac chat stays the completions streamer gated by showsChat`() throws {
        #expect(APIClient.chatCompletionsPath == "/v1/chat/completions")
        #expect(!ChatAvailability.visible(catalog: nil))
        #expect(!ChatAvailability.visible(anyReachable: true, modelCount: 0))
        #expect(ChatAvailability.visible(anyReachable: true, modelCount: 1))
        #expect(AppRoute.chat.title == "Chat")
        #expect(PhoneTab.chat.rawValue == "chat")
        let body = ChatCompletionBody(
            model: "llama3:latest",
            stream: true,
            messages: [ChatWireMessage(role: "user", content: "hi")],
        )
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any]
        #expect(object?["stream"] as? Bool == true)
        #expect(ChatWebSession.routePath == "/chat")
    }
}
