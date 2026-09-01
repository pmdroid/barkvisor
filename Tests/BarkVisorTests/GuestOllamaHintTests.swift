import Foundation
import Testing

struct GuestOllamaHintTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `feature forbids Guest Ollama 11434 hint and keeps Models how-to`() throws {
        let feature = try read("features/guest-ollama-hint.feature")
        #expect(feature.contains("Guest Ollama"))
        #expect(feature.contains("127.0.0.1:11434"))
        #expect(feature.contains("Models"))
        #expect(feature.contains("Home"))
        #expect(feature.contains("Device"))
        #expect(feature.contains("Workload"))
    }

    @Test func `web and Console GPU copy have no Guest Ollama loopback hint`() throws {
        let files = [
            "frontend/src/utils/gpuPassthrough.ts",
            "frontend/src/views/VMDetailView.vue",
            "frontend/src/views/DeviceDetailView.vue",
            "Apps/BarkVisorConsole/Sources/Views/WorkloadDetailView.swift",
            "Apps/BarkVisorConsole/Sources/Views/DeviceDetailView.swift",
            "Apps/BarkVisorConsole/Sources/Models/Models.swift",
        ]
        for path in files {
            let source = try read(path)
            #expect(!source.contains("Guest Ollama"))
            #expect(!source.contains("127.0.0.1:11434"))
        }
        let copy = try read("Apps/BarkVisorConsole/Sources/Models/Models.swift")
        #expect(copy.contains("same card cannot be host and guest"))
        #expect(copy.contains("Attach a GPU like USB"))
    }

    @Test func `models how-to still documents host inference`() throws {
        let web = try read("frontend/src/utils/inferenceApiHowTo.ts")
        #expect(web.contains("OPENAI_BASE_URL"))
        #expect(web.contains("HOME_LISTEN_PORT = 7777"))
        #expect(web.contains("CAGE_OPENAI_BASE_URL"))
        let console = try read("Apps/BarkVisorConsole/Sources/Models/InferenceAPIHowTo.swift")
        #expect(console.contains("OPENAI_BASE_URL"))
        #expect(console.contains("listenPort"))
        #expect(console.contains("cageBaseURL"))
    }
}
