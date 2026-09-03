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

    /// Hostname only from a saved advertise URL (`https://box.ts.net:443` → `box.ts.net`).
    static func advertiseHostName(_ raw: String?) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.contains("://") {
            guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else {
                return ""
            }
            return stripListenHost(host)
        }
        if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") {
            let inner = String(trimmed[trimmed.index(after: trimmed.startIndex) ..< close])
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty || rest.hasPrefix(":") {
                return stripListenHost(inner)
            }
        }
        if let colon = trimmed.lastIndex(of: ":"), trimmed.firstIndex(of: ":") == colon {
            let after = trimmed[trimmed.index(after: colon)...]
            if !after.isEmpty, after.allSatisfy(\.isNumber) {
                return stripListenHost(String(trimmed[..<colon]))
            }
        }
        return stripListenHost(trimmed)
    }

    /// MagicDNS, then tailnet IP. Empty when Tailscale is down.
    static func tailnetListenHost(_ tailscale: RemoteAccessTailnet?) -> String {
        guard let tailscale, tailscale.available else { return "" }
        let dns = stripListenHost(tailscale.dnsName ?? "")
        if !dns.isEmpty { return dns }
        return stripListenHost(tailscale.ip ?? "")
    }

    /// saved advertise host > tailnet > (member / origin).
    static func preferredListenHost(advertiseHost: String?, tailnetHost: String?) -> String {
        let advertised = advertiseHostName(advertiseHost)
        if !advertised.isEmpty { return advertised }
        return stripListenHost(tailnetHost ?? "")
    }

    static func lanListenHost(
        role: InferenceHostRole,
        originHost: String,
        memberHost: String?,
        advertiseHost: String? = nil,
        tailnetHost: String? = nil,
    ) -> String {
        let preferred = preferredListenHost(advertiseHost: advertiseHost, tailnetHost: tailnetHost)
        if !preferred.isEmpty { return preferred }
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
        advertiseHost: String? = nil,
        tailnetHost: String? = nil,
    ) -> Int {
        if !preferredListenHost(advertiseHost: advertiseHost, tailnetHost: tailnetHost).isEmpty {
            return listenPort
        }
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
        advertiseHost: String? = nil,
        tailnetHost: String? = nil,
    ) -> String {
        let preferred = preferredListenHost(advertiseHost: advertiseHost, tailnetHost: tailnetHost)
        if !preferred.isEmpty {
            let formatted = DeviceURL.formatHomeDeviceURL(preferred)
            if !formatted.isEmpty { return formatted }
            let host = formatListenHost(preferred)
            let resolvedHost = host.isEmpty ? "127.0.0.1" : host
            return "http://\(resolvedHost):\(listenPort)"
        }
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
        advertiseHost: String? = nil,
        tailnetHost: String? = nil,
    ) -> Snippets {
        let key = apiKey(grantPlaintext)
        let origin = lanOrigin(
            role: role,
            originHost: originHost,
            originPort: originPort,
            originScheme: originScheme,
            memberHost: memberHost,
            advertiseHost: advertiseHost,
            tailnetHost: tailnetHost,
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
        advertiseHost: String? = nil,
        tailnetHost: String? = nil,
    ) -> Snippets {
        snippets(
            role: role,
            originHost: origin?.host ?? "127.0.0.1",
            originPort: origin?.port,
            originScheme: origin?.scheme,
            memberHost: memberHost,
            grantPlaintext: grantPlaintext,
            advertiseHost: advertiseHost,
            tailnetHost: tailnetHost,
        )
    }
}
