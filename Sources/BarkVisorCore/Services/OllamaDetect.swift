import Foundation

/// Find host Ollama without requiring it to install BarkVisor (PAS-269).
public enum OllamaDetect {
    public static let defaultEndpoint = "http://127.0.0.1:11434"

    public static var macInstallHint: String {
        "Install Ollama with Homebrew: brew install ollama"
    }

    public static var linuxInstallHint: String {
        "Ollama is optional. Install the distro package or see https://ollama.com/download"
    }

    public static func installHint(os: String = PlatformHost.platformName) -> String {
        os.lowercased() == "linux" ? linuxInstallHint : macInstallHint
    }

    public static func candidatePaths(os: String = PlatformHost.platformName) -> [String] {
        if os.lowercased() == "linux" {
            return [
                "/usr/local/bin/ollama",
                "/usr/bin/ollama",
            ]
        }
        return [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
    }

    public struct Probe: Sendable {
        public var os: String
        public var isExecutable: @Sendable (String) -> Bool
        public var whichPath: String?

        public init(
            os: String = PlatformHost.platformName,
            isExecutable: @escaping @Sendable (String) -> Bool = {
                FileManager.default.isExecutableFile(atPath: $0)
            },
            whichPath: String? = nil,
        ) {
            self.os = os
            self.isExecutable = isExecutable
            self.whichPath = whichPath
        }

        public static let live = Probe()
    }

    public static func detect(probe: Probe = .live) -> OllamaDetectResult {
        let hint = installHint(os: probe.os)
        var paths = candidatePaths(os: probe.os)
        if let which = probe.whichPath, !which.isEmpty {
            paths.append(which)
        }
        if let found = paths.first(where: { probe.isExecutable($0) }) {
            return OllamaDetectResult(installed: true, binaryPath: found, installHint: hint)
        }
        return OllamaDetectResult(installed: false, binaryPath: nil, installHint: hint)
    }

    /// Live PATH lookup via `/usr/bin/which`. Tests inject `whichPath` instead.
    public static func whichOllama() -> String? {
        guard let result = try? PlatformProcess.run(
            path: "/usr/bin/which",
            arguments: ["ollama"],
            timeout: 5,
        ), result.succeeded else {
            return nil
        }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    public static func liveDetect() -> OllamaDetectResult {
        detect(probe: Probe(whichPath: whichOllama()))
    }
}
