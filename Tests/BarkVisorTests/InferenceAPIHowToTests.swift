import Foundation
import Testing
@testable import BarkVisorCore

struct InferenceAPIHowToTests {
    @Test func `console and frontend assemble LAN :7777/v1 and cage slirp`() throws {
        let root = repoRoot()
        let console = try String(
            contentsOf: root.appendingPathComponent(
                "Apps/BarkVisorConsole/Sources/Models/InferenceAPIHowTo.swift",
            ),
            encoding: .utf8,
        )
        let frontend = try String(
            contentsOf: root.appendingPathComponent("frontend/src/utils/inferenceApiHowTo.ts"),
            encoding: .utf8,
        )
        for source in [console, frontend] {
            #expect(source.contains("7777"))
            #expect(source.contains("/v1/chat/completions"))
            #expect(source.contains("/v1"))
            #expect(source.contains("10.0.2.2:11434/v1"))
            #expect(source.contains("slirp"))
            #expect(source.contains("Authorization: Bearer"))
            #expect(source.contains("OPENAI_BASE_URL"))
            #expect(source.contains("OPENAI_API_KEY"))
            #expect(source.contains("<inference-key>"))
            #expect(source.contains("advertiseHost"))
            #expect(source.contains("tailnetHost"))
            #expect(!source.contains(":7778"))
        }
        #expect(CodingAgentImage.deviceOllamaBaseURL == "http://10.0.2.2:11434/v1")
        #expect(AgentNetworkCage.slirpGateway == "10.0.2.2")
        #expect(AgentNetworkCage.ollamaPort == 11_434)
    }
}

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
    }
    Issue.record("could not find Package.swift from \(#filePath)")
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}
