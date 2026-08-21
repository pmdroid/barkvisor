import Foundation

/// Best-effort WireGuard presence. BarkVisor does not configure tunnels (PAS-89).
public enum WireGuardProbe {
    public static let candidatePaths = [
        "/usr/bin/wg",
        "/usr/local/bin/wg",
        "/opt/homebrew/bin/wg",
    ]

    public static func isWireGuardInterfaceName(_ name: String) -> Bool {
        if name == "wg" { return true }
        guard name.hasPrefix("wg") else { return false }
        return name.dropFirst(2).allSatisfy(\.isNumber) && name.count > 2
    }

    public static func detect(
        interfaces: [HostInterfaceInfo] = HostInfoService.listInterfaces(),
        executablePath: String? = nil,
        invoke: (@Sendable (String, [String]) throws -> CommandResult)? = nil,
    ) -> WireGuardInfo {
        if interfaces.contains(where: { isWireGuardInterfaceName($0.name) }) {
            return WireGuardInfo(configured: true)
        }
        let path = executablePath
            ?? candidatePaths.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path else { return WireGuardInfo(configured: false) }
        let run = invoke ?? { try PlatformProcess.run(path: $0, arguments: $1, timeout: 2) }
        guard let result = try? run(path, ["show", "interfaces"]), result.succeeded else {
            return WireGuardInfo(configured: false)
        }
        let names = result.stdoutString.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return WireGuardInfo(configured: names.contains { isWireGuardInterfaceName($0) } || !names.isEmpty)
    }
}
