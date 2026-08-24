import Foundation

/// LAN vs in-cage how-to for the OpenAI-compatible surface (GitHub #212).
/// LAN is Home :7777 `/v1/chat/completions`, not Device :11434.
enum InferenceHostRole: Equatable {
    case thisDevice
    case member
}

enum InferenceAPIHowTo {
    static let listenPort = DeviceURL.defaultPort
    static let completionsPath = "/v1/chat/completions"
    static let openAIV1Suffix = "/v1"
    static let cageBaseURL = "http://10.0.2.2:11434/v1"
    static let cageDnsLine = "Cage DNS is slirp."
    static let missingKey = "<inference-key>"

    struct Snippets: Equatable {
        var lanBaseURL: String
        var lanCompletionsURL: String
        var apiKey: String
        var curl: String
        var env: String
        var cageBaseURL: String
        var cageEnv: String
        var cageDnsLine: String
    }

    static func stripListenHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        return value
    }

    static func formatListenHost(_ host: String) -> String {
        let trimmed = stripListenHost(host)
        return trimmed.contains(":") ? "[\(trimmed)]" : trimmed
    }

    static func lanListenHost(
        role: InferenceHostRole,
        originHost: String,
        memberHost: String?,
    ) -> String {
        if role == .member {
            let member = stripListenHost(memberHost ?? "")
            if !member.isEmpty { return member }
        }
        return stripListenHost(originHost)
    }

    static func lanListenPort(
        role: InferenceHostRole,
        originPort: Int?,
        memberHost: String?,
    ) -> Int {
        if role == .member, !stripListenHost(memberHost ?? "").isEmpty {
            return listenPort
        }
        if let originPort, originPort > 0 { return originPort }
        return listenPort
    }

    static func lanOrigin(
        role: InferenceHostRole,
        originHost: String,
        originPort: Int?,
        originScheme: String?,
        memberHost: String?,
    ) -> String {
        let memberDirect = role == .member && !stripListenHost(memberHost ?? "").isEmpty
        let raw = memberDirect
            ? "http"
            : (originScheme ?? "http").trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
        let scheme = raw == "https" ? "https" : "http"
        let host = formatListenHost(lanListenHost(
            role: role, originHost: originHost, memberHost: memberHost,
        ))
        let resolvedHost = host.isEmpty ? "127.0.0.1" : host
        let port = lanListenPort(role: role, originPort: originPort, memberHost: memberHost)
        let omit = (scheme == "http" && port == 80) || (scheme == "https" && port == 443)
        return omit ? "\(scheme)://\(resolvedHost)" : "\(scheme)://\(resolvedHost):\(port)"
    }

    static func apiKey(_ grantPlaintext: String?) -> String {
        let trimmed = grantPlaintext?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? missingKey : trimmed
    }

    static func curl(completionsURL: String, apiKey: String) -> String {
        """
        curl \(completionsURL) \\
          -H 'Authorization: Bearer \(apiKey)' \\
          -H 'Content-Type: application/json' \\
          -d '{"model":"llama3","messages":[{"role":"user","content":"Hello"}]}'
        """
    }

    static func env(baseURL: String, apiKey: String) -> String {
        "export OPENAI_BASE_URL='\(baseURL)'\nexport OPENAI_API_KEY='\(apiKey)'"
    }

    static func snippets(
        role: InferenceHostRole,
        originHost: String,
        originPort: Int?,
        originScheme: String?,
        memberHost: String?,
        grantPlaintext: String?,
    ) -> Snippets {
        let key = apiKey(grantPlaintext)
        let origin = lanOrigin(
            role: role,
            originHost: originHost,
            originPort: originPort,
            originScheme: originScheme,
            memberHost: memberHost,
        )
        let lanBase = origin + openAIV1Suffix
        let lanCompletions = origin + completionsPath
        return Snippets(
            lanBaseURL: lanBase,
            lanCompletionsURL: lanCompletions,
            apiKey: key,
            curl: curl(completionsURL: lanCompletions, apiKey: key),
            env: env(baseURL: lanBase, apiKey: key),
            cageBaseURL: cageBaseURL,
            cageEnv: env(baseURL: cageBaseURL, apiKey: key),
            cageDnsLine: cageDnsLine,
        )
    }

    static func snippets(
        role: InferenceHostRole,
        origin: URL?,
        memberHost: String?,
        grantPlaintext: String? = nil,
    ) -> Snippets {
        snippets(
            role: role,
            originHost: origin?.host ?? "127.0.0.1",
            originPort: origin?.port,
            originScheme: origin?.scheme,
            memberHost: memberHost,
            grantPlaintext: grantPlaintext,
        )
    }
}
