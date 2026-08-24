import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama detect (PAS-269)")
struct OllamaDetectTests {
    @Test func `mac prefers homebrew then usr local then app bundle`() {
        let paths = OllamaDetect.candidatePaths(os: "macos")
        #expect(paths.first == "/opt/homebrew/bin/ollama")
        #expect(paths.contains("/usr/local/bin/ollama"))
        #expect(paths.contains("/Applications/Ollama.app/Contents/Resources/ollama"))
        #expect(!paths.contains("/usr/bin/ollama"))
        #expect(OllamaDetect.installHint(os: "macos").contains("brew install ollama"))
    }

    @Test func `linux uses distro paths not homebrew`() {
        let paths = OllamaDetect.candidatePaths(os: "linux")
        #expect(paths.contains("/usr/bin/ollama"))
        #expect(paths.contains("/usr/local/bin/ollama"))
        #expect(!paths.contains("/opt/homebrew/bin/ollama"))
        #expect(OllamaDetect.installHint(os: "linux").lowercased().contains("optional"))
    }

    @Test func `detect uses injected executable probe not this host`() {
        let missing = OllamaDetect.detect(
            probe: .init(os: "macos", isExecutable: { _ in false }, whichPath: nil),
        )
        #expect(!missing.installed)
        #expect(missing.binaryPath == nil)

        let brew = OllamaDetect.detect(
            probe: .init(
                os: "macos",
                isExecutable: { $0 == "/opt/homebrew/bin/ollama" },
                whichPath: nil,
            ),
        )
        #expect(brew.installed)
        #expect(brew.binaryPath == "/opt/homebrew/bin/ollama")

        let pathHit = OllamaDetect.detect(
            probe: .init(
                os: "linux",
                isExecutable: { $0 == "/home/runner/bin/ollama" },
                whichPath: "/home/runner/bin/ollama",
            ),
        )
        #expect(pathHit.installed)
        #expect(pathHit.binaryPath == "/home/runner/bin/ollama")
    }
}
