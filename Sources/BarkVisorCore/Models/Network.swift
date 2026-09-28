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
    /// here": an omitted `host` inherits the bind of the stored publication it
    /// continues. Widening on purpose stays possible with an explicit `host`
    /// (including `0.0.0.0`).
    ///
    /// A publish is identified by where it is *published* (`proto` + `hostPort`),
    /// not by where it lands, so a retargeted `guestPort` still continues the
    /// same publication and keeps its bind. Which stored publication is being
    /// continued is resolved in order:
    ///
    /// 1. exactly one stored rule on this `proto` + `hostPort` — unambiguous;
    /// 2. otherwise the one that also repeats this `guestPort` — unambiguous;
    /// 3. otherwise **ambiguous**, and rejected rather than guessed, because any
    ///    choice silently moves a bind the client did not mention.
    ///
    /// A rule with no stored rule on its host port is new and keeps the
    /// documented default (absent = every IPv4 interface).
    public static func inherited(
        from incoming: [PortForwardRule],
        existing: [PortForwardRule],
    ) throws -> [PortForwardRule] {
        guard !incoming.isEmpty, !existing.isEmpty else { return incoming }
        return try incoming.map { rule in
            guard rule.host == nil else { return rule }
            let onPort = existing.filter {
                Self.normalizedProtocol($0.protocol) == Self.normalizedProtocol(rule.protocol)
                    && $0.hostPort == rule.hostPort
            }
            guard let prior = onPort.count == 1
                ? onPort[0]
                : onPort.first(where: { $0.guestPort == rule.guestPort })
            else {
                guard onPort.isEmpty else {
                    throw BarkVisorError.badRequest(
                        "portForwards entry \(rule.hostPort)/\(rule.protocol) omits host, but this "
                            + "workload already publishes that host port on several binds "
                            + "(\(binds(onPort).joined(separator: ", "))). "
                            + "Send host to choose the one to keep.",
                    )
                }
                return rule
            }
            return rule.replacingHost(prior.host)
        }
    }

    private static func binds(_ rules: [PortForwardRule]) -> [String] {
        Array(Set(rules.map { $0.host ?? PortRegistry.wildcardBind })).sorted()
    }

    /// Same rule with a different bind. `0.0.0.0` is normalized back to an
    /// absent bind so an explicit wildcard and an omitted one stay one value.
    private func replacingHost(_ host: String?) -> PortForwardRule {
        PortForwardRule(
            protocol: `protocol`,
            hostPort: hostPort,
            guestPort: guestPort,
            httpPath: httpPath,
            host: host == PortRegistry.wildcardBind ? nil : host,
        )
    }

    static func normalizedProtocol(_ proto: String) -> String {
        proto.lowercased()
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
