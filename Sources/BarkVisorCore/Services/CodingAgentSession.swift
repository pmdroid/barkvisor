import Foundation

/// Coding Agent in the VM (PAS-272): start, proxy, env.
///
/// Agent-class cage (PAS-268) plus the Coding Agent image (PAS-271). Chat is
/// Home `/v1/chat/completions`. Terminal is the serial console. ttyd stays
/// loopback-only so the cage does not publish a host port.
public struct CodingAgentPlan: Equatable, Sendable {
    public let vmID: String
    public let grant: String
    public let openaiBaseURL: String
    public let openaiAPIKey: String
    public let chatPath: String
    public let terminalPath: String
    public let webTerminalGuestPort: Int
    public let webTerminalHostPort: Int
    public let surfaces: [String]

    public var env: [String: String] {
        CodingAgentSession.env(self)
    }

    public var loopbackHostfwd: String {
        CodingAgentSession.loopbackHostfwd(
            hostPort: webTerminalHostPort,
            guestPort: webTerminalGuestPort,
        )
    }
}

public enum CodingAgentSession {
    public static let grant = "home-ollama"
    public static let chatPath = "/v1/chat/completions"
    public static let surfaces = ["chat", "terminal"]

    public static func terminalPath(vmID: String) -> String {
        "/api/vms/\(vmID)/console"
    }

    public static func homeOllamaGrantURL() -> String {
        CodingAgentImage.homeOllamaGrantURL
    }

    public static func start(
        vmID: String,
        isCodingImage: Bool,
        workloadClass: WorkloadClass,
        openaiBaseURL: String? = nil,
        grantPlaintext: String,
        terminalHostPort: Int,
    ) throws -> CodingAgentPlan {
        guard isCodingImage else {
            throw BarkVisorError.badRequest("Coding Agent session needs the Coding Agent image")
        }
        guard workloadClass == .agent else {
            throw BarkVisorError.badRequest("Coding Agent session needs the Agent cage")
        }
        let key = grantPlaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw BarkVisorError.badRequest("Home Ollama grant is missing")
        }
        try QEMUBuilder.validatePort(terminalHostPort)
        let url = try CodingAgentImage.normalizeOpenAIBaseURL(openaiBaseURL)
        return CodingAgentPlan(
            vmID: vmID,
            grant: grant,
            openaiBaseURL: url,
            openaiAPIKey: key,
            chatPath: chatPath,
            terminalPath: terminalPath(vmID: vmID),
            webTerminalGuestPort: CodingAgentImage.webTerminalPort,
            webTerminalHostPort: terminalHostPort,
            surfaces: surfaces,
        )
    }

    public static func env(_ plan: CodingAgentPlan) -> [String: String] {
        env(openaiBaseURL: plan.openaiBaseURL, grantPlaintext: plan.openaiAPIKey)
    }

    public static func env(openaiBaseURL: String, grantPlaintext: String) -> [String: String] {
        [
            "OPENAI_BASE_URL": openaiBaseURL,
            "OPENAI_API_KEY": grantPlaintext,
        ]
    }

    public static func loopbackHostfwd(hostPort: Int, guestPort: Int = CodingAgentImage.webTerminalPort)
        -> String {
        "hostfwd=tcp:127.0.0.1:\(hostPort)-:\(guestPort)"
    }

    public static func wantsWebTerminal(userData: String?) -> Bool {
        guard let userData, !userData.isEmpty else { return false }
        return userData.contains("ttyd") && userData.contains("\(CodingAgentImage.webTerminalPort)")
    }

    public static func usesHomeOllamaGrant(userData: String?) -> Bool {
        AgentNetworkCage.allowHostOllama(userData: userData)
    }
}

/// Loopback ttyd hostfwd ports for running Coding Agent VMs (not spec.portForwards).
public actor CodingAgentSessionStore {
    public static let shared = CodingAgentSessionStore()

    private var terminalHostPort: [String: Int] = [:]

    public func record(vmID: String, terminalHostPort port: Int) {
        terminalHostPort[vmID] = port
    }

    public func port(for vmID: String) -> Int? {
        terminalHostPort[vmID]
    }

    public func occupiedHostPorts() -> [Int] {
        Array(terminalHostPort.values)
    }

    public func remove(vmID: String) {
        terminalHostPort.removeValue(forKey: vmID)
    }
}
