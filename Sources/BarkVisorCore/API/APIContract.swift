import Foundation

/// Published HTTP contract (PAS-78).
///
/// **Versioning decision:** unversioned `/api` *is* v1. Clients read
/// `X-BarkVisor-API-Version` and `AgentInfo.apiVersion`. Breaking changes bump
/// both and get a deprecation window; `/api/v2` only if additive change is
/// impossible. Platform differences are capabilities + the existing
/// `{error,code,reason,status}` envelope — never divergent resource schemas.
public enum APIContract {
    public static let version = 1
    public static let versionHeaderName = "X-BarkVisor-API-Version"
    public static let openapiPath = "/api/openapi.yaml"
    public static let contractPath = "/api/contract"

    public static let urlVersioning = """
    Unversioned /api is v1. Breaking changes bump \(versionHeaderName) and \
    AgentInfo.apiVersion after a deprecation window. Prefer additive fields; \
    /api/v2 only if unavoidable.
    """

    public enum Stability: String, Codable, Sendable, CaseIterable {
        case stable
        case evolving
        case internalAccess = "internal"
        case outOfBand = "out-of-band"
    }

    public struct Route: Codable, Sendable, Equatable {
        public var method: String
        public var path: String
        public var stability: Stability

        public var operation: String {
            "\(method) \(path)"
        }

        public init(method: String, path: String, stability: Stability) {
            self.method = method
            self.path = path
            self.stability = stability
        }
    }

    /// Route inventory the OpenAPI document must cover (and vice versa).
    public static let routes: [Route] = [
        // Stable public
        Route(method: "GET", path: "/api/health", stability: .stable),
        Route(method: "GET", path: "/api/openapi.yaml", stability: .stable),
        Route(method: "GET", path: "/api/contract", stability: .stable),
        Route(method: "POST", path: "/api/auth/login", stability: .stable),
        Route(method: "POST", path: "/api/auth/refresh", stability: .stable),
        Route(method: "POST", path: "/api/auth/logout", stability: .stable),
        Route(method: "GET", path: "/api/auth/me", stability: .stable),
        Route(method: "POST", path: "/api/auth/login-offers", stability: .evolving),
        Route(method: "GET", path: "/api/auth/login-offers", stability: .evolving),
        Route(method: "DELETE", path: "/api/auth/login-offers", stability: .evolving),
        Route(method: "POST", path: "/api/auth/login-offers/redeem", stability: .evolving),

        // Stable resources
        Route(method: "GET", path: "/api/vms", stability: .stable),
        Route(method: "POST", path: "/api/vms", stability: .stable),
        Route(method: "GET", path: "/api/vms/{id}", stability: .stable),
        Route(method: "PATCH", path: "/api/vms/{id}", stability: .stable),
        Route(method: "DELETE", path: "/api/vms/{id}", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/start", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/stop", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/restart", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/session/resume", stability: .evolving),
        Route(method: "POST", path: "/api/vms/{id}/session/reset", stability: .evolving),
        Route(method: "POST", path: "/api/vms/{id}/session/burn", stability: .evolving),
        Route(method: "POST", path: "/api/vms/{id}/attach-iso", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/detach-iso", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/usb", stability: .stable),
        Route(method: "DELETE", path: "/api/vms/{id}/usb/{deviceId}", stability: .stable),
        Route(method: "POST", path: "/api/vms/{id}/gpu", stability: .stable),
        Route(method: "DELETE", path: "/api/vms/{id}/gpu/{deviceId}", stability: .stable),
        Route(method: "GET", path: "/api/vms/{id}/spec", stability: .stable),
        Route(method: "PUT", path: "/api/vms/{id}/spec", stability: .stable),
        Route(method: "POST", path: "/api/workloads/apply", stability: .stable),
        Route(method: "GET", path: "/api/workloads/{id}/spec", stability: .stable),
        Route(method: "GET", path: "/api/workloadspec.schema.json", stability: .stable),

        Route(method: "GET", path: "/api/disks", stability: .stable),
        Route(method: "POST", path: "/api/disks", stability: .stable),
        Route(method: "GET", path: "/api/disks/summary", stability: .stable),
        Route(method: "GET", path: "/api/disks/{id}", stability: .stable),
        Route(method: "GET", path: "/api/disks/{id}/usage", stability: .stable),
        Route(method: "POST", path: "/api/disks/{id}/resize", stability: .stable),
        Route(method: "DELETE", path: "/api/disks/{id}", stability: .stable),

        Route(method: "GET", path: "/api/networks", stability: .stable),
        Route(method: "GET", path: "/api/networks/modes", stability: .stable),
        Route(method: "POST", path: "/api/networks", stability: .stable),
        Route(method: "PATCH", path: "/api/networks/{id}", stability: .stable),
        Route(method: "DELETE", path: "/api/networks/{id}", stability: .stable),

        Route(method: "GET", path: "/api/images", stability: .stable),
        Route(method: "GET", path: "/api/images/{id}", stability: .stable),
        Route(method: "DELETE", path: "/api/images/{id}", stability: .stable),
        Route(method: "POST", path: "/api/images/download", stability: .stable),

        // Evolving — same schema on every host, may still change before 1.0
        Route(method: "GET", path: "/api/system/capabilities", stability: .evolving),
        Route(method: "GET", path: "/api/system/usb-devices", stability: .evolving),
        Route(method: "GET", path: "/api/system/usb", stability: .evolving),
        Route(method: "GET", path: "/api/system/gpu-devices", stability: .evolving),
        Route(method: "GET", path: "/api/system/gpu", stability: .evolving),
        Route(method: "GET", path: "/api/system/about", stability: .evolving),
        Route(method: "GET", path: "/api/system/library/settings", stability: .evolving),
        Route(method: "PUT", path: "/api/system/library/settings", stability: .evolving),
        Route(method: "GET", path: "/api/system/remote-access", stability: .evolving),
        Route(method: "PUT", path: "/api/home/settings/remote-access", stability: .evolving),
        Route(method: "GET", path: "/api/agent/inventory", stability: .evolving),
        Route(method: "GET", path: "/api/agent/whoami", stability: .outOfBand),
        Route(method: "GET", path: "/api/agent/library/images", stability: .outOfBand),
        Route(method: "GET", path: "/api/agent/library/images/{id}/content", stability: .outOfBand),
        Route(method: "POST", path: "/api/pairing/codes", stability: .evolving),
        Route(method: "GET", path: "/api/pairing/codes", stability: .evolving),
        Route(method: "DELETE", path: "/api/pairing/codes", stability: .evolving),
        Route(method: "POST", path: "/api/pairing/redeem", stability: .evolving),
        Route(method: "POST", path: "/api/pairing/join", stability: .evolving),
        Route(method: "GET", path: "/api/home/devices", stability: .evolving),
        Route(method: "GET", path: "/api/home/devices/health", stability: .evolving),
        Route(method: "POST", path: "/api/home/placement/score", stability: .evolving),
        Route(method: "GET", path: "/api/ollama/status", stability: .evolving),
        Route(method: "GET", path: "/api/ollama/snapshot", stability: .evolving),
        Route(method: "GET", path: "/api/ollama/tags", stability: .evolving),
        Route(method: "GET", path: "/api/ollama/ps", stability: .evolving),
        Route(method: "POST", path: "/api/ollama/pull", stability: .evolving),
        Route(method: "POST", path: "/api/ollama/start", stability: .evolving),
        Route(method: "POST", path: "/api/ollama/stop", stability: .evolving),
        Route(method: "GET", path: "/api/ollama/settings", stability: .evolving),
        Route(method: "PUT", path: "/api/ollama/settings", stability: .evolving),
        Route(method: "POST", path: "/api/ollama/v1/chat/completions", stability: .evolving),
        Route(method: "GET", path: "/api/home/ollama/status", stability: .evolving),
        Route(method: "GET", path: "/api/home/ollama/models", stability: .evolving),
        Route(method: "POST", path: "/api/home/ollama/pull", stability: .evolving),
        Route(method: "POST", path: "/api/home/ollama/start", stability: .evolving),
        Route(method: "POST", path: "/api/home/ollama/stop", stability: .evolving),
        Route(method: "GET", path: "/api/tags", stability: .evolving),
        Route(method: "POST", path: "/api/pull", stability: .evolving),
        Route(method: "GET", path: "/api/ps", stability: .evolving),
        Route(method: "GET", path: "/api/v1/models", stability: .evolving),
        Route(method: "POST", path: "/api/v1/chat/completions", stability: .evolving),
        Route(method: "GET", path: "/v1/models", stability: .evolving),
        Route(method: "POST", path: "/v1/chat/completions", stability: .evolving),
        Route(method: "GET", path: "/api/home/devices/{id}/v1/{path}", stability: .internalAccess),
        Route(method: "POST", path: "/api/home/devices/{id}/v1/{path}", stability: .internalAccess),
        Route(method: "PUT", path: "/api/home/devices/{id}/v1/{path}", stability: .internalAccess),
        Route(method: "PATCH", path: "/api/home/devices/{id}/v1/{path}", stability: .internalAccess),
        Route(method: "DELETE", path: "/api/home/devices/{id}/v1/{path}", stability: .internalAccess),
        Route(method: "GET", path: "/api/vms/{id}/guest-info", stability: .evolving),
        Route(method: "GET", path: "/api/vms/{id}/health", stability: .evolving),
        Route(method: "PUT", path: "/api/vms/{id}/health", stability: .evolving),
        Route(method: "POST", path: "/api/vms/{id}/health/probe", stability: .evolving),
        Route(method: "GET", path: "/api/workloads/health-summary", stability: .evolving),

        // Out-of-band transports (documented, not JSON contract)
        Route(method: "GET", path: "/api/vms/{id}/state", stability: .outOfBand),
        Route(method: "POST", path: "/api/auth/ws-ticket", stability: .outOfBand),
        Route(method: "GET", path: "/api/vms/{id}/console", stability: .outOfBand),
        Route(method: "GET", path: "/api/vms/{id}/vnc", stability: .outOfBand),
        Route(method: "GET", path: "/api/home/devices/{id}/v1/vms/{vmId}/console", stability: .outOfBand),
        Route(method: "GET", path: "/api/home/devices/{id}/v1/vms/{vmId}/vnc", stability: .outOfBand),
    ]

    /// Prefixes reserved for later waves — not implemented as routes today.
    public static let reservedPrefixes: [(prefix: String, stability: Stability)] = [
        ("/api/apps", .evolving),
    ]

    public static func routes(stability: Stability) -> [Route] {
        routes.filter { $0.stability == stability }
    }

    public static func specURL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "openapi",
            withExtension: "yaml",
            subdirectory: "API",
        ) ?? Bundle.module.url(forResource: "openapi", withExtension: "yaml") {
            return bundled
        }
        return nil
    }

    public static func specYAML() throws -> String {
        guard let url = specURL() else {
            throw APIContractError.specMissing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    public static func workloadSpecSchemaURL() -> URL? {
        if let bundled = Bundle.module.url(
            forResource: "workloadspec.schema",
            withExtension: "json",
            subdirectory: "API",
        ) ?? Bundle.module.url(forResource: "workloadspec.schema", withExtension: "json") {
            return bundled
        }
        return nil
    }

    public static func workloadSpecSchemaJSON() throws -> String {
        guard let url = workloadSpecSchemaURL() else {
            throw APIContractError.specMissing
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

public enum APIContractError: Error, Sendable {
    case specMissing
}

/// Machine-readable contract summary (`GET /api/contract`).
public struct APIContractSummary: Codable, Sendable, Equatable {
    public var apiVersion: Int
    public var versionHeader: String
    public var urlVersioning: String
    public var openapi: String
    public var errorEnvelope: [String]
    public var tiers: [String: [String]]
    public var reserved: [String: [String]]

    public static var current: APIContractSummary {
        var tiers: [String: [String]] = [:]
        for stability in APIContract.Stability.allCases {
            let ops = APIContract.routes(stability: stability).map(\.operation).sorted()
            if !ops.isEmpty {
                tiers[stability.rawValue] = ops
            }
        }
        var reserved: [String: [String]] = [:]
        for item in APIContract.reservedPrefixes {
            reserved[item.stability.rawValue, default: []].append(item.prefix)
        }
        for key in reserved.keys {
            reserved[key]?.sort()
        }
        return APIContractSummary(
            apiVersion: APIContract.version,
            versionHeader: APIContract.versionHeaderName,
            urlVersioning: APIContract.urlVersioning,
            openapi: APIContract.openapiPath,
            errorEnvelope: ["error", "code", "reason", "status"],
            tiers: tiers,
            reserved: reserved,
        )
    }
}
