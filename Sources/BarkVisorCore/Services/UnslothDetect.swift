import Foundation

public enum UnslothDetect {
    public static var installHint: String {
        "Install Unsloth with: curl -fsSL https://unsloth.ai/install.sh | sh"
    }

    public static func candidatePaths(os: String = PlatformHost.platformName) -> [String] {
        if os.lowercased() == "linux" {
            return [
                "/usr/local/bin/unsloth",
                "/usr/bin/unsloth",
            ]
        }
        return [
            "/opt/homebrew/bin/unsloth",
            "/usr/local/bin/unsloth",
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
        var paths = candidatePaths(os: probe.os)
        if let which = probe.whichPath, !which.isEmpty {
            paths.append(which)
        }
        if let found = paths.first(where: { probe.isExecutable($0) }) {
            return OllamaDetectResult(installed: true, binaryPath: found, installHint: installHint)
        }
        return OllamaDetectResult(installed: false, binaryPath: nil, installHint: installHint)
    }

    public static func whichUnsloth() -> String? {
        guard let result = try? PlatformProcess.run(
            path: "/usr/bin/which",
            arguments: ["unsloth"],
            timeout: 5,
        ), result.succeeded else {
            return nil
        }
        let output = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    public static func liveDetect() -> OllamaDetectResult {
        detect(probe: Probe(whichPath: whichUnsloth()))
    }
}
