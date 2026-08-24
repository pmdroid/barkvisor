import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama catalog merge (PAS-269)")
struct OllamaCatalogTests {
    @Test func `merge tags and ps marks running and keeps pulled`() {
        let tags = [
            OllamaTagRecord(name: "llama3:latest", digest: "sha-a", size: 4_000),
            OllamaTagRecord(name: "phi3:latest", digest: "sha-b", size: 2_000),
        ]
        let running = [
            OllamaRunningRecord(name: "llama3:latest", digest: "sha-a", size: 4_000, sizeVRAM: 3_000),
        ]
        let merged = OllamaCatalog.merge(tags: tags, running: running)
        #expect(merged.count == 2)
        let llama = merged.first { $0.name == "llama3:latest" }
        let phi = merged.first { $0.name == "phi3:latest" }
        #expect(llama?.running == true)
        #expect(llama?.sizeVRAM == 3_000)
        #expect(phi?.running == false)
        #expect(phi?.size == 2_000)
        #expect(phi?.sizeVRAM == nil)
        let ps = OllamaCatalog.nativePS(from: merged)
        #expect(ps.models.count == 1)
        #expect(ps.models[0].sizeVRAM == 3_000)
    }

    @Test func `running-only model still appears`() {
        let merged = OllamaCatalog.merge(
            tags: [],
            running: [OllamaRunningRecord(name: "guest:latest", size: 10)],
        )
        #expect(merged.count == 1)
        #expect(merged[0].running)
        #expect(merged[0].name == "guest:latest")
    }

    @Test func `name without tag matches latest`() {
        #expect(OllamaModelName.canonical("Llama3") == "llama3:latest")
        #expect(OllamaModelName.matches("llama3", available: "llama3:latest"))
        #expect(OllamaModelName.matches("llama3:latest", available: "llama3"))
        #expect(!OllamaModelName.matches("llama3", available: "phi3:latest"))
    }

    @Test func `home map drops unreachable and stale devices`() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = iso8601.string(from: now)
        let stale = iso8601.string(from: now.addingTimeInterval(-120))
        let snapshots = [
            OllamaDeviceSnapshot(
                hostId: "desk",
                displayName: "desk",
                installed: true,
                reachable: true,
                installHint: "brew",
                probedAt: fresh,
                models: [
                    OllamaLocalModel(name: "llama3:latest", size: 100, sizeVRAM: 80, running: true),
                ],
                memoryTotalMB: 32_768,
                memoryUsedMB: 4_096,
                cpuLoadPercent: 10,
            ),
            OllamaDeviceSnapshot(
                hostId: "down",
                installed: true,
                reachable: false,
                installHint: "brew",
                probedAt: fresh,
                models: [OllamaLocalModel(name: "llama3:latest", size: 100, running: true)],
            ),
            OllamaDeviceSnapshot(
                hostId: "quiet",
                installed: true,
                reachable: true,
                installHint: "brew",
                probedAt: stale,
                models: [OllamaLocalModel(name: "phi3:latest", size: 50, running: false)],
            ),
        ]
        let catalog = OllamaHomeMap.catalog(from: snapshots, now: now, staleAfter: 90)
        #expect(catalog.anyReachable)
        #expect(catalog.models.count == 1)
        #expect(catalog.models[0].name == "llama3:latest")
        #expect(catalog.models[0].locations.map(\.hostId) == ["desk"])
        #expect(catalog.models[0].locations[0].sizeVRAM == 80)
        #expect(catalog.devices.first { $0.hostId == "down" }?.reachable == false)
        #expect(catalog.devices.first { $0.hostId == "quiet" }?.stale == true)
        let json = try OllamaPSExport.jsonString(from: catalog.models)
        let decoded = try JSONDecoder().decode(OllamaPSExportDocument.self, from: Data(json.utf8))
        #expect(decoded.models.count == 1)
        #expect(decoded.models[0].name == "llama3:latest")
        #expect(decoded.models[0].size == 100)
        #expect(decoded.models[0].sizeVRAM == 80)
        #expect(decoded.models[0].running)
        #expect(decoded.models[0].host == "desk")
        #expect(json.contains("\"sizeVRAM\" : 80") || json.contains("\"sizeVRAM\": 80"))
    }
}
