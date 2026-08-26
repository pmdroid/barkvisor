import Foundation

public enum DaemonRole: String, Sendable {
    case home
    case agent

    public static func from(executablePath: String) -> DaemonRole {
        let name = URL(fileURLWithPath: executablePath).lastPathComponent
        if name == "barkvisor-agent" {
            return .agent
        }
        return .home
    }

    public var commandName: String {
        switch self {
        case .home: "barkvisor"
        case .agent: "barkvisor-agent"
        }
    }

    public var serveFrontend: Bool {
        self == .home
    }
}
