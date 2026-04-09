import Foundation
import GRDB

public struct CreateNetworkParams: Sendable {
    public let name: String
    public let mode: String
    public let bridge: String?
    public let macAddress: String?
    public let dnsServer: String?

    public init(name: String, mode: String, bridge: String?, macAddress: String?, dnsServer: String?) {
        self.name = name
        self.mode = mode
        self.bridge = bridge
        self.macAddress = macAddress
        self.dnsServer = dnsServer
    }
}

public struct UpdateNetworkParams: Sendable {
    public let id: String
    public let name: String?
    public let mode: String?
    public let bridge: String?
    public let macAddress: String?
    public let dnsServer: String?

    public init(
        id: String, name: String?, mode: String?, bridge: String?, macAddress: String?,
        dnsServer: String?,
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.bridge = bridge
        self.macAddress = macAddress
        self.dnsServer = dnsServer
    }
}

public enum NetworkService {
    /// Create a new network after validation.
    public static func create(
        _ params: CreateNetworkParams,
        db: DatabasePool,
    ) async throws -> Network {
        guard ["nat", "bridged"].contains(params.mode) else {
            throw BarkVisorError.badRequest("mode must be 'nat' or 'bridged'")
        }
        if params.mode == "bridged", (params.bridge ?? "").isEmpty {
            throw BarkVisorError.badRequest("bridge interface required for bridged mode")
        }

        if let bridge = params.bridge, !bridge.isEmpty { try validateBridgeName(bridge) }
        if let dns = params.dnsServer, !dns.isEmpty { try validateDNS(dns) }
        if let mac = params.macAddress, !mac.isEmpty { try validateMAC(mac) }

        if params.mode == "bridged", let bridge = params.bridge, !bridge.isEmpty {
            let conflict = try await db.read { db in
                try Network.filter(Column("bridge") == bridge).fetchOne(db)
            }
            if let conflict {
                throw BarkVisorError.conflict(
                    "Interface '\(bridge)' is already used by network \"\(conflict.name)\". Each interface can only have one bridge.",
                )
            }
        }

        let network = Network(
            id: UUID().uuidString, name: params.name, mode: params.mode, bridge: params.bridge,
            macAddress: params.macAddress, dnsServer: params.dnsServer, autoCreated: false,
            isDefault: false,
        )
        try await db.write { db in
            try network.insert(db)
        }
        return network
    }

    /// Update a network's fields after validation.
    public static func update(
        _ params: UpdateNetworkParams,
        db: DatabasePool,
    ) async throws -> Network {
        let network = try await db.read { db in try Network.fetchOne(db, key: params.id) }
        guard var network else { throw BarkVisorError.notFound() }
        guard !network.isDefault else {
            throw BarkVisorError.forbidden("The default \(network.mode) network cannot be modified")
        }

        if let name = params.name { network.name = name }
        if let mode = params.mode {
            guard ["nat", "bridged"].contains(mode) else {
                throw BarkVisorError.badRequest("mode must be 'nat' or 'bridged'")
            }
            network.mode = mode
        }
        if let bridge = params.bridge {
            if !bridge.isEmpty { try validateBridgeName(bridge) }
            network.bridge = bridge
        }
        if let mac = params.macAddress {
            if !mac.isEmpty { try validateMAC(mac) }
            network.macAddress = mac
        }
        if let dns = params.dnsServer {
            if !dns.isEmpty { try validateDNS(dns) }
            network.dnsServer = dns
        }

        if network.mode == "bridged", let bridge = network.bridge, !bridge.isEmpty {
            let conflict = try await db.read { db in
                try Network
                    .filter(Column("bridge") == bridge)
                    .filter(Column("id") != params.id)
                    .fetchOne(db)
            }
            if let conflict {
                throw BarkVisorError.conflict(
                    "Interface '\(bridge)' is already used by network \"\(conflict.name)\". Each interface can only have one bridge.",
                )
            }
        }

        let updatedNetwork = network
        try await db.write { db in
            try updatedNetwork.update(db)
        }
        return network
    }

    /// Delete a network, checking for attached VMs.
    public static func delete(id: String, db: DatabasePool) async throws -> Network? {
        let network = try await db.read { db in try Network.fetchOne(db, key: id) }
        guard network?.isDefault != true else {
            throw BarkVisorError.forbidden("Cannot delete the default network")
        }
        let vmCount = try await db.read { db in
            try VM.filter(Column("networkId") == id).fetchCount(db)
        }
        guard vmCount == 0 else {
            throw BarkVisorError.conflict("Cannot delete network: \(vmCount) VM(s) are still attached")
        }
        _ = try await db.write { db in try Network.deleteOne(db, key: id) }
        return network
    }
}
