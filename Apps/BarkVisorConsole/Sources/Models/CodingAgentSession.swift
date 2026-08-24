import Foundation

/// Coding Agent in the VM (PAS-272): Chat or Terminal, Home Ollama grant.
enum CodingAgentSession {
    static let grant = "home-ollama"
    static let chatPath = "/v1/chat/completions"
    static let surfaces = ["chat", "terminal"]

    static func terminalPath(vmID: String) -> String {
        "/api/vms/\(vmID)/console"
    }

    static func isSession(workloadClass: String?) -> Bool {
        workloadClass == "agent"
    }

    static func surfaces(workloadClass: String?) -> [String] {
        isSession(workloadClass: workloadClass) ? surfaces : []
    }

    static func env(grantPlaintext: String, openaiBaseURL: String = CodingAgentImage.homeOllamaGrantURL)
        -> [String: String] {
        [
            "OPENAI_BASE_URL": openaiBaseURL,
            "OPENAI_API_KEY": grantPlaintext,
        ]
    }

    static func consoleTitle(isSession: Bool) -> String {
        isSession ? "Terminal" : "Console"
    }

    static let noPushCopy = "NO PUSH"
    static let expiryAction = "stop"
    static let warningLeadSeconds = 15 * 60

    static func warningCopy(remainingSeconds: Int?) -> String {
        let minutes = max(1, Int(ceil(Double(remainingSeconds ?? 0) / 60.0)))
        return minutes == 1
            ? "Session expires in 1 minute. Push your changes. TTL stop keeps the disk."
            : "Session expires in \(minutes) minutes. Push your changes. TTL stop keeps the disk."
    }
}

struct CodingAgentReceipt: Decodable, Hashable {
    var stoppedAt: String
    var reason: String
    var lastGitPushAt: String?
    var noPush: Bool
}

struct CodingAgentSessionInfo: Decodable, Hashable {
    var ttlSeconds: Int
    var startedAt: String?
    var expiresAt: String?
    var remainingSeconds: Int?
    var warning: Bool
    var warningLeadSeconds: Int
    var expiryAction: String
    var grant: String
    var receipt: CodingAgentReceipt?
    var actions: [String]

    func receiptLine(vmState: String) -> (stoppedAt: String, git: String, loud: Bool)? {
        guard vmState == "stopped" || vmState == "error" else { return nil }
        guard let receipt else { return nil }
        let missing = receipt.noPush || (receipt.lastGitPushAt ?? "").isEmpty
        return (
            receipt.stoppedAt,
            missing ? CodingAgentSession.noPushCopy : (receipt.lastGitPushAt ?? CodingAgentSession.noPushCopy),
            missing,
        )
    }
}
