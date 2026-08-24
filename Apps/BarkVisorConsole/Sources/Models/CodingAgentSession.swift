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
}
