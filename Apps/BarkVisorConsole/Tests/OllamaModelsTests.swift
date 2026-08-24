import Foundation
import Testing
@testable import BarkVisorConsole

struct OllamaModelsTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func startBodyOmitsHostIdSoHomePicks() throws {
        let data = try encoder.encode(OllamaModelActionBody.start("llama3:latest", hostId: nil))
        let object = try decoder.decode([String: String].self, from: data)
        #expect(object["name"] == "llama3:latest")
        #expect(object["hostId"] == nil)
    }

    @Test func startBodyIncludesHostIdWhenPicked() throws {
        let data = try encoder.encode(OllamaModelActionBody.start("llama3:latest", hostId: "desk"))
        let object = try decoder.decode([String: String].self, from: data)
        #expect(object["name"] == "llama3:latest")
        #expect(object["hostId"] == "desk")
    }

    @Test func nameFilterIsCaseInsensitiveAndIgnoresBlankQuery() {
        let row = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: nil,
            running: false,
            locations: [],
        )
        #expect(row.matchesName(""))
        #expect(row.matchesName("  "))
        #expect(row.matchesName("LLAMA"))
        #expect(!row.matchesName("mistral"))
    }

    @Test func localPullUsesDeviceTaskPath() {
        #expect(OllamaTaskPath.rest(taskID: "t1", hostId: "self", selfHostId: "self") == "/api/tasks/t1")
    }

    @Test func memberPullUsesHomeProxyTaskPath() {
        #expect(
            OllamaTaskPath.rest(taskID: "t1", hostId: "peer", selfHostId: "self")
                == "/api/home/devices/peer/v1/tasks/t1",
        )
    }

    @Test func catalogDecodesAndTaskPercentIs0to100() throws {
        let json = """
        {
          "anyReachable": true,
          "anyInstalled": true,
          "models": [
            {
              "name": "llama3:latest",
              "running": false,
              "locations": [
                { "hostId": "desk", "running": false, "reachable": true }
              ]
            }
          ],
          "devices": [
            {
              "hostId": "desk",
              "displayName": "Desk",
              "installed": true,
              "reachable": true,
              "stale": false,
              "installHint": "brew install ollama"
            }
          ]
        }
        """.data(using: .utf8)!
        let catalog = try decoder.decode(OllamaHomeCatalog.self, from: json)
        #expect(catalog.anyReachable)
        #expect(catalog.models[0].name == "llama3:latest")
        let event = try decoder.decode(
            OllamaTaskEvent.self,
            from: Data(#"{"taskID":"t1","kind":"ollamaPull","status":"running","progress":0.42}"#.utf8),
        )
        #expect(event.percent == 42)
        #expect(event.isTerminal == false)
    }
}
