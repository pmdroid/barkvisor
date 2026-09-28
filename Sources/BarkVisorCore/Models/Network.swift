import Foundation
import GRDB

public struct Network: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "networks"

    public var id: String
    public var name: String
    public var mode: String
    public var bridge: String?
    public var macAddress: String?
    public var dnsServer: String?
    public var autoCreated: Bool
    public var isDefault: Bool

    public init(
        id: String,
        name: String,
        mode: String,
        bridge: String?,
        macAddress: String?,
        dnsServer: String?,
        autoCreated: Bool,
        isDefault: Bool,
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.bridge = bridge
        self.macAddress = macAddress
        self.dnsServer = dnsServer
        self.autoCreated = autoCreated
        self.isDefault = isDefault
    }
}

public struct PortForwardRule: Codable, Equatable, Sendable {
    public let `protocol`: String
    public let hostPort: Int
    public let guestPort: Int
    public let httpPath: String?
    public let host: String?

    /// Spec → column. The one adapter every spec write path uses.
    ///
    /// `WorkloadPortForward` has no `httpPath`, so a spec cannot set it: a
    /// spec write clears any `httpPath` the column already held. `host` is the
    /// bind address (absent = every IPv4 interface) and is carried verbatim.
    public init(_ forward: WorkloadPortForward) {
        self.init(
            protocol: forward.proto,
            hostPort: forward.hostPort,
            guestPort: forward.guestPort,
            host: forward.host,
        )
    }

    public init(
        protocol: String,
        hostPort: Int,
        guestPort: Int,
        httpPath: String? = nil,
        host: String? = nil,
    ) {
        self.protocol = `protocol`
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.httpPath = httpPath
        self.host = host
    }

    /// Merge semantics for a spec write whose `portForwards[].host` is omitted.
    ///
    /// A spec apply/PUT/PATCH replaces the whole list, so an element without
    /// `host` would otherwise rebind an existing `127.0.0.1` publish to every
    /// IPv4 interface without the client asking for it. Omitted means "unchanged
    /// here": an omitted `host` inherits the bind of the `existing` rule it
    /// replaces, matched on `proto` + `hostPort` + `guestPort`. To widen a bind
    /// on purpose, send an explicit `host` (including `0.0.0.0`). A rule with
    /// no `existing` counterpart is new, so it keeps the documented default
    /// (absent = every IPv4 interface).
    public static func inherited(
        from incoming: [PortForwardRule],
        existing: [PortForwardRule],
    ) -> [PortForwardRule] {
        guard !incoming.isEmpty, !existing.isEmpty else { return incoming }
        return incoming.map { rule in
            guard rule.host == nil else { return rule }
            guard let prior = existing.first(where: {
                $0.protocol.lowercased() == rule.protocol.lowercased()
                    && $0.hostPort == rule.hostPort
                    && $0.guestPort == rule.guestPort
            }) else { return rule }
            return PortForwardRule(
                protocol: rule.protocol,
                hostPort: rule.hostPort,
                guestPort: rule.guestPort,
                httpPath: rule.httpPath,
                host: prior.host,
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case `protocol`
        case hostPort
        case guestPort
        case httpPath
        case host
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.protocol = try container.decode(String.self, forKey: .protocol)
        hostPort = try container.decode(Int.self, forKey: .hostPort)
        guestPort = try container.decode(Int.self, forKey: .guestPort)
        httpPath = try container.decodeIfPresent(String.self, forKey: .httpPath)
        host = try container.decodeIfPresent(String.self, forKey: .host)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(`protocol`, forKey: .protocol)
        try container.encode(hostPort, forKey: .hostPort)
        try container.encode(guestPort, forKey: .guestPort)
        try container.encodeIfPresent(httpPath, forKey: .httpPath)
        try container.encodeIfPresent(host, forKey: .host)
    }
}
