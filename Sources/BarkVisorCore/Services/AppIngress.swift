import Foundation

public struct WorkloadIngress: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var mode: String?
    public var extraEnv: [String: String]?
    public var hostPort: Int?
    public var extraBinds: [String]?

    public init(
        enabled: Bool = true,
        mode: String? = nil,
        extraEnv: [String: String]? = nil,
        hostPort: Int? = nil,
        extraBinds: [String]? = nil,
    ) {
        self.enabled = enabled
        self.mode = mode
        self.extraEnv = extraEnv
        self.hostPort = hostPort
        self.extraBinds = extraBinds
    }
}

public enum AppIngress {
    public static let cookieName = "barkvisor"
    public static let modePrefix = "prefix"
    public static let modeDirect = "direct"

    public static let managedKeys: Set<String> = [
        "SUBFOLDER",
        "APP_URL",
        "GITEA__server__ROOT_URL",
        "GITEA__server__DOMAIN",
        "PAPERLESS_URL",
        "PAPERLESS_CSRF_TRUSTED_ORIGINS",
        "PHOTOPRISM_SITE_URL",
        "GF_SERVER_ROOT_URL",
        "GF_SERVER_SERVE_FROM_SUB_PATH",
        "BARKVISOR_BASE_PATH",
        "BARKVISOR_PUBLIC_URL",
        "TRUSTED_PROXIES",
        "OVERWRITEPROTOCOL",
        "OVERWRITEHOST",
        "OVERWRITEWEBROOT",
    ]

    public static func isEnabled(_ ingress: WorkloadIngress?) -> Bool {
        ingress?.enabled ?? true
    }

    public static func resolvedMode(catalogProxy: String?, override: String?) -> String {
        let chosen = (override?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? catalogProxy ?? ""
        if chosen.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == modePrefix {
            return modePrefix
        }
        return modeDirect
    }

    public static func usesPrefix(catalogProxy: String?, ingress: WorkloadIngress?) -> Bool {
        isEnabled(ingress) && resolvedMode(catalogProxy: catalogProxy, override: ingress?.mode) == modePrefix
    }

    public static func basePath(id: String) -> String {
        "/go/\(id)/"
    }

    public static func homePath(hostId: String, id: String) -> String {
        "/home/devices/\(hostId)/go/\(id)/"
    }

    public static func isProxyPath(_ path: String) -> Bool {
        if path == "/go" || path.hasPrefix("/go/") { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count >= 4 && parts[0] == "home" && parts[1] == "devices" && parts[3] == "go"
    }

    public static func publicURL(scheme: String, host: String, listenPort: Int, id: String) -> String {
        var builtScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtScheme.isEmpty { builtScheme = "http" }
        let wrapped = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let defaultPort = builtScheme == "https" ? 443 : 80
        if listenPort == defaultPort {
            return "\(builtScheme)://\(wrapped)\(basePath(id: id))"
        }
        return "\(builtScheme)://\(wrapped):\(listenPort)\(basePath(id: id))"
    }

    public static func origin(scheme: String, host: String, listenPort: Int) -> String {
        var builtScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        if builtScheme.isEmpty { builtScheme = "http" }
        let wrapped = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let defaultPort = builtScheme == "https" ? 443 : 80
        if listenPort == defaultPort {
            return "\(builtScheme)://\(wrapped)"
        }
        return "\(builtScheme)://\(wrapped):\(listenPort)"
    }

    public static func openURL(
        id: String,
        catalogProxy: String?,
        ingress: WorkloadIngress?,
        lanURL: String?,
        listenHost: String?,
        listenPort: Int,
        scheme: String = "http",
    ) -> String? {
        if usesPrefix(catalogProxy: catalogProxy, ingress: ingress) {
            let host = (listenHost?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "127.0.0.1"
            return publicURL(scheme: scheme, host: host, listenPort: listenPort, id: id)
        }
        return lanURL
    }

    public static func managedEnv(
        id: String,
        names: [String],
        catalogProxy: String?,
        ingress: WorkloadIngress?,
        scheme: String,
        host: String,
        listenPort: Int,
    ) -> [String: String] {
        guard usesPrefix(catalogProxy: catalogProxy, ingress: ingress) else { return [:] }
        let path = basePath(id: id)
        let url = publicURL(scheme: scheme, host: host, listenPort: listenPort, id: id)
        let origin = origin(scheme: scheme, host: host, listenPort: listenPort)
        let listed = Set(names)
        var out: [String: String] = [
            "BARKVISOR_BASE_PATH": path,
            "BARKVISOR_PUBLIC_URL": url,
        ]
        func include(_ key: String) -> Bool {
            listed.contains(key)
        }
        if include("SUBFOLDER") { out["SUBFOLDER"] = path }
        if include("APP_URL") { out["APP_URL"] = url }
        if include("GITEA__server__ROOT_URL") { out["GITEA__server__ROOT_URL"] = url }
        if include("GITEA__server__DOMAIN") { out["GITEA__server__DOMAIN"] = host }
        if include("PAPERLESS_URL") { out["PAPERLESS_URL"] = url }
        if include("PAPERLESS_CSRF_TRUSTED_ORIGINS") { out["PAPERLESS_CSRF_TRUSTED_ORIGINS"] = origin }
        if include("PHOTOPRISM_SITE_URL") { out["PHOTOPRISM_SITE_URL"] = url }
        if include("GF_SERVER_ROOT_URL") { out["GF_SERVER_ROOT_URL"] = url }
        if include("GF_SERVER_SERVE_FROM_SUB_PATH") { out["GF_SERVER_SERVE_FROM_SUB_PATH"] = "true" }
        if include("TRUSTED_PROXIES") { out["TRUSTED_PROXIES"] = "127.0.0.1" }
        if include("OVERWRITEPROTOCOL") { out["OVERWRITEPROTOCOL"] = scheme.isEmpty ? "http" : scheme }
        if include("OVERWRITEHOST") { out["OVERWRITEHOST"] = host }
        if include("OVERWRITEWEBROOT") { out["OVERWRITEWEBROOT"] = path }
        return out
    }

    public static func envNames(catalog: AppCatalogUI, schema: [AppCatalogEnvVar]) -> [String] {
        var names = Set(catalog.basePathEnv)
        let schemaNames = Set(schema.map(\.name))
        for key in managedKeys where schemaNames.contains(key) {
            names.insert(key)
        }
        names.formUnion(catalog.basePathEnv)
        return names.sorted()
    }

    public static func mergeEnv(
        existing: [String: String]?,
        extra: [String: String]?,
        managed: [String: String],
        enabled: Bool,
    ) -> [String: String]? {
        var out = existing ?? [:]
        if let extra {
            for (key, value) in extra {
                if managedKeys.contains(key) { continue }
                if key.hasPrefix("BARKVISOR_") { continue }
                out[key] = value
            }
        }
        if enabled {
            for (key, value) in managed {
                out[key] = value
            }
        } else {
            for key in managedKeys {
                out.removeValue(forKey: key)
            }
            out.removeValue(forKey: "BARKVISOR_BASE_PATH")
            out.removeValue(forKey: "BARKVISOR_PUBLIC_URL")
        }
        return out.isEmpty ? nil : out
    }

    public static func stripForwardHeaders(_ headers: [(String, String)]) -> [(String, String)] {
        headers.compactMap { name, value in
            let lower = name.lowercased()
            if lower == "authorization" { return nil }
            if lower == "cookie" {
                let kept = stripCookies(value)
                if kept.isEmpty { return nil }
                return (name, kept)
            }
            if lower == "cookie2" { return nil }
            return (name, value)
        }
    }

    public static func stripCookies(_ header: String) -> String {
        header.split(separator: ";").compactMap { part -> String? in
            let item = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = item.firstIndex(of: "=") else { return item.isEmpty ? nil : item }
            let name = item[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            if name == cookieName { return nil }
            if name.lowercased().hasPrefix("barkvisor") { return nil }
            return item
        }.joined(separator: "; ")
    }

    public static func loopbackURL(port: Int, path: String, query: String?) throws -> URL {
        guard (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("Invalid published port")
        }
        var raw = "http://127.0.0.1:\(port)\(path)"
        if let query, !query.isEmpty {
            raw += "?\(query)"
        }
        guard let url = URL(string: raw) else {
            throw BarkVisorError.badRequest("Unable to build ingress URL")
        }
        return url
    }

    public static func uiPort(ports: [PublishedPort], override: Int?) -> Int? {
        if let override, (1 ... 65_535).contains(override) { return override }
        if let ui = ports.first(where: { $0.proto.lowercased() == "tcp" }) {
            return ui.hostPort
        }
        return nil
    }

    public static func isPublishedPort(_ port: Int, ports: [PublishedPort]) -> Bool {
        ports.contains { $0.hostPort == port && $0.proto.lowercased() == "tcp" }
    }
}
