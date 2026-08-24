import Foundation
import Testing
@testable import BarkVisorConsole

struct OllamaModelsTests {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    @Test func `start body omits host id so home picks`() throws {
        let data = try encoder.encode(OllamaModelActionBody.start("llama3:latest", hostId: nil))
        let object = try decoder.decode([String: String].self, from: data)
        #expect(object["name"] == "llama3:latest")
        #expect(object["hostId"] == nil)
    }

    @Test func `start body includes host id when picked`() throws {
        let data = try encoder.encode(OllamaModelActionBody.start("llama3:latest", hostId: "desk"))
        let object = try decoder.decode([String: String].self, from: data)
        #expect(object["name"] == "llama3:latest")
        #expect(object["hostId"] == "desk")
    }

    @Test func `stop uses live running host not snapshot`() {
        let stale = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: nil,
            running: true,
            locations: [
                OllamaModelLocation(hostId: "old", displayName: nil, running: true, reachable: true),
            ],
        )
        let live = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: nil,
            running: true,
            locations: [
                OllamaModelLocation(hostId: "old", displayName: nil, running: false, reachable: true),
                OllamaModelLocation(hostId: "desk", displayName: nil, running: true, reachable: true),
            ],
        )
        #expect(stale.runningHostId == "old")
        #expect(OllamaCatalogModel.runningHostId(name: stale.name, in: [live]) == "desk")
        let stopped = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: nil,
            running: false,
            locations: [
                OllamaModelLocation(hostId: "desk", displayName: nil, running: false, reachable: true),
            ],
        )
        #expect(OllamaCatalogModel.runningHostId(name: "llama3:latest", in: [stopped]) == nil)
        #expect(OllamaCatalogModel.runningHostId(name: "missing", in: [live]) == nil)
    }

    @Test func `name filter is case insensitive and ignores blank query`() {
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

    @Test func `local pull uses device task path`() {
        #expect(OllamaTaskPath.rest(taskID: "t1", hostId: "self", selfHostId: "self") == "/api/tasks/t1")
    }

    @Test func `ps export round trip keeps null size VRAM`() throws {
        let llama = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: 4_000,
            running: true,
            locations: [
                OllamaModelLocation(
                    hostId: "desk",
                    displayName: nil,
                    running: true,
                    reachable: true,
                    size: 4_000,
                    sizeVRAM: 3_000,
                ),
                OllamaModelLocation(
                    hostId: "lab",
                    displayName: nil,
                    running: false,
                    reachable: true,
                    size: 4_000,
                    sizeVRAM: nil,
                ),
            ],
        )
        let export = OllamaPsExport.serialize([llama])
        #expect(export.models.count == 2)
        #expect(export.models[0].name == "llama3:latest")
        #expect(export.models[0].size == 4_000)
        #expect(export.models[0].sizeVRAM == 3_000)
        #expect(export.models[0].running)
        #expect(export.models[0].host == "desk")
        #expect(export.models[1].sizeVRAM == nil)
        #expect(export.models[1].running == false)
        #expect(export.models[1].host == "lab")
        let json = try export.jsonString()
        let decoded = try decoder.decode(OllamaPsExport.self, from: Data(json.utf8))
        #expect(decoded == export)
        #expect(json.contains("\"sizeVRAM\" : null") || json.contains("\"sizeVRAM\": null"))
        #expect(json.hasSuffix("\n"))
        let fileURL = try export.writeJSONFile()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        #expect(fileURL.lastPathComponent == OllamaPsExport.filename)
        #expect(fileURL.lastPathComponent == "ollama-ps.json")
        let fileText = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(fileText == json)
    }

    @Test func `models view shares export JSON`() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let url = tests.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Views/ModelsView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("Home holds upstream keys per"))
        #expect(source.contains("OllamaSettingsUpdate.saveKey(hostId:"))
        #expect(!source.contains("apiKey: keyDraft"))
        #expect(!source.contains("saved on this Device"))
        #expect(source.contains("ShareLink("))
        #expect(source.contains("OllamaPsShareFile(models: catalog.models)"))
        #expect(source.contains("SharePreview(OllamaPsExport.filename)"))
        #expect(!source.contains("ShareLink(item: exportJSON)"))
        #expect(!source.contains("private var exportJSON"))
        #expect(source.contains("Export JSON"))
        #expect(source.contains("Menu {"))
        #expect(source.contains("ellipsis.circle"))
        #expect(source.contains("DeviceStatsHistory.points"))
        #expect(source.contains("OllamaDeviceStats.gpuEmptyCopy"))
        #expect(source.contains("LineMark("))
        #expect(source.contains("AreaMark("))
        #expect(source.contains("statsHistory(on:"))
        let modelsSource = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Models/OllamaModels.swift"),
            encoding: .utf8,
        )
        #expect(modelsSource.contains("FileRepresentation(exportedContentType: .json)"))
        #expect(modelsSource.contains("suggestedFileName(OllamaPsExport.filename)"))
        #expect(modelsSource.contains("static let filename = \"ollama-ps.json\""))
    }

    @Test func `member pull uses home proxy task path`() {
        #expect(
            OllamaTaskPath.rest(taskID: "t1", hostId: "peer", selfHostId: "self")
                == "/api/home/devices/peer/v1/tasks/t1",
        )
    }

    @Test func `settings snapshot decodes hosts and omits raw key`() throws {
        let json = """
        {
          "hosts": [
            {
              "hostId": "desk",
              "endpoint": "http://127.0.0.1:11434",
              "hasApiKey": true
            }
          ]
        }
        """.data(using: .utf8)!
        let snapshot = try decoder.decode(OllamaSettingsSnapshot.self, from: json)
        #expect(snapshot.host("desk")?.hasApiKey == true)
        let encoded = try encoder.encode(
            OllamaSettingsUpdate(hostId: "desk", apiKey: "secret"),
        )
        let object = try decoder.decode([String: String].self, from: encoded)
        #expect(object["hostId"] == "desk")
        #expect(object["apiKey"] == "secret")
        #expect(object["endpoint"] == nil)
        #expect(OllamaSettingsUpdate.saveKey(hostId: "desk", draft: "") == nil)
        #expect(OllamaSettingsUpdate.saveKey(hostId: "desk", draft: "   ") == nil)
        #expect(OllamaSettingsUpdate.saveKey(hostId: "", draft: "secret") == nil)
        #expect(
            OllamaSettingsUpdate.saveKey(hostId: " desk ", draft: " secret ")
                == OllamaSettingsUpdate(hostId: "desk", apiKey: "secret"),
        )
        let omitted = try encoder.encode(OllamaSettingsUpdate(hostId: "desk"))
        let omittedObject = try decoder.decode([String: String].self, from: omitted)
        #expect(omittedObject["apiKey"] == nil)
        let cleared = try encoder.encode(OllamaSettingsUpdate(hostId: "desk", apiKey: ""))
        let clearedObject = try decoder.decode([String: String].self, from: cleared)
        #expect(clearedObject["apiKey"] == "")
    }

    @Test func `live stats defaults to running device and skips unreachable`() {
        let llama = OllamaCatalogModel(
            name: "llama3:latest",
            digest: nil,
            size: nil,
            running: true,
            locations: [
                OllamaModelLocation(hostId: "lab", displayName: nil, running: false, reachable: true),
                OllamaModelLocation(hostId: "desk", displayName: nil, running: true, reachable: true),
            ],
        )
        let desk = OllamaDeviceStatus(
            hostId: "desk",
            displayName: "Desk",
            installed: true,
            reachable: true,
            stale: false,
            installHint: "",
        )
        let down = OllamaDeviceStatus(
            hostId: "down",
            displayName: "Garage",
            installed: true,
            reachable: false,
            stale: false,
            installHint: "",
        )
        #expect(OllamaDeviceStats.defaultHostId(models: [llama], devices: [down, desk]) == "desk")
        #expect(OllamaDeviceStats.defaultHostId(models: [], devices: [down, desk]) == "desk")
        #expect(!OllamaDeviceStats.shouldFetch(catalogDevice: down, health: nil))
        #expect(OllamaDeviceStats.shouldFetch(catalogDevice: desk, health: nil))
        let memberDown = HomeDeviceHealthSnapshot(
            hostId: "desk",
            role: "member",
            displayName: "Desk",
            fingerprint: nil,
            agentHost: nil,
            agentPort: 7_777,
            pairedAt: nil,
            reachability: "unreachable",
            reachabilityError: "Device is unreachable",
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
        #expect(!OllamaDeviceStats.shouldFetch(catalogDevice: desk, health: memberDown))
        #expect(OllamaDeviceStats.unreachableCopy.contains("unknown"))
        #expect(OllamaDeviceStats.unreachableCopy.contains(Copy.device.lowercased()))
        #expect(!OllamaDeviceStats.unreachableCopy.localizedCaseInsensitiveContains("node"))
    }

    @Test func `gpu devices decode occupancy and empty copy`() throws {
        let json = """
        [
          {
            "id": "0000:01:00.0",
            "pciAddress": "0000:01:00.0",
            "iommuGroup": "14",
            "vendorId": "10de",
            "deviceId": "2684",
            "name": "NVIDIA",
            "driver": "nvidia",
            "vfioBound": false,
            "inUseByHost": true,
            "attachable": true,
            "groupAddresses": ["0000:01:00.0", "0000:01:00.1"]
          }
        ]
        """.data(using: .utf8)!
        let gpus = try decoder.decode([HostGPUDevice].self, from: json)
        #expect(gpus.count == 1)
        let lines = OllamaDeviceStats.occupancyLines(gpus[0])
        #expect(lines.contains("NVIDIA"))
        #expect(lines.contains("nvidia"))
        #expect(lines.contains("In use by host"))
        #expect(lines.contains("Group mates: 0000:01:00.1"))
        #expect(!lines.joined(separator: " ").contains("%"))
        #expect(OllamaDeviceStats.gpuEmptyCopy.contains("no GPU"))
        #expect(!OllamaDeviceStats.gpuEmptyCopy.localizedCaseInsensitiveContains("util"))
        let samples = try decoder.decode(
            [SystemStatsSample].self,
            from: Data(
                """
                [
                  {
                    "timestamp": "2026-08-23T12:00:00Z",
                    "hostCpuPercent": 12.4,
                    "hostMemoryUsedMB": 8192,
                    "hostMemoryTotalMB": 32768
                  }
                ]
                """.utf8,
            ),
        )
        let points = DeviceStatsHistory.points(from: samples)
        #expect(points.count == 1)
        #expect(points[0].cpuPercent == 12.4)
        #expect(points[0].memoryUsedGB == 8)
    }

    @Test func `catalog decodes and task percent is 0 to 100`() throws {
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
