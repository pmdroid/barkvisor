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
        let mode = try NetworkCapability.parse(params.mode)
        try NetworkCapability.requireMode(params.mode)
        if mode == .bridged {
            guard let bridge = params.bridge, !bridge.isEmpty else {
                throw BarkVisorError.badRequest("bridge interface required for bridged mode")
            }
            try NetworkCapability.requireBridgedInterface(bridge)
        } else if let bridge = params.bridge, !bridge.isEmpty {
            throw BarkVisorError.badRequest("bridge is only valid for bridged mode")
        }

        if let bridge = params.bridge, !bridge.isEmpty { try validateBridgeName(bridge) }
        if let dns = params.dnsServer, !dns.isEmpty { try validateDNS(dns) }
        if let mac = params.macAddress, !mac.isEmpty { try validateMAC(mac) }

        if mode == .bridged, let bridge = params.bridge, !bridge.isEmpty {
            let conflict = try await db.read { db in
                try Network.filter(Column("bridge") == bridge).fetchOne(db)
            }
            try HostBridgeFactsService.requireUnusedBridgedInterface(bridge, occupiedBy: conflict)
        }

        let storedBridge = mode == .bridged ? params.bridge : nil
        let network = Network(
            id: UUID().uuidString, name: params.name, mode: params.mode, bridge: storedBridge,
            macAddress: params.macAddress, dnsServer: params.dnsServer, autoCreated: false,
            isDefault: false,
        )
        try await db.write { db in
            try network.insert(db)
        }
        return network
    }

    /// Ensure a bridged `Network` row exists for a host interface (setup / system bridge install).
    /// Returns the existing row when present; otherwise creates an auto-created bridged network.
    /// Does not install the managed bridge daemon — call PrivilegeService separately.
    @discardableResult
    public static func ensureBridgedNetwork(
        for interface: String,
        db: DatabasePool,
    ) async throws -> Network {
        let existing = try await db.read { db in
            try Network.filter(Column("bridge") == interface).fetchOne(db)
        }
        if let existing {
            return existing
        }

        try NetworkCapability.requireBridgedInterface(interface)

        let network = Network(
            id: UUID().uuidString,
            name: "Bridged (\(interface))",
            mode: "bridged",
            bridge: interface,
            macAddress: nil,
            dnsServer: nil,
            autoCreated: true,
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
            try NetworkCapability.requireMode(mode)
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

        let mode = try NetworkCapability.parse(network.mode)
        if mode == .bridged {
            let bridge = network.bridge ?? ""
            if bridge.isEmpty {
                throw BarkVisorError.badRequest("bridge interface required for bridged mode")
            }
            try NetworkCapability.requireBridgedInterface(bridge)
        } else {
            if let requested = params.bridge, !requested.isEmpty {
                throw BarkVisorError.badRequest("bridge is only valid for bridged mode")
            }
            network.bridge = nil
        }

        if mode == .bridged, let bridge = network.bridge, !bridge.isEmpty {
            let conflict = try await db.read { db in
                try Network
                    .filter(Column("bridge") == bridge)
                    .filter(Column("id") != params.id)
                    .fetchOne(db)
            }
            try HostBridgeFactsService.requireUnusedBridgedInterface(bridge, occupiedBy: conflict)
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

    public static func attachedWorkloadCount(bridge: String, db: DatabasePool) async throws -> Int {
        try await db.read { db in
            let nets = try Network.filter(Column("bridge") == bridge).fetchAll(db)
            let ids = nets.map(\.id)
            if ids.isEmpty { return 0 }
            return try VM.filter(ids.contains(Column("networkId"))).fetchCount(db)
        }
    }

    public static func deleteUnattached(bridge: String, db: DatabasePool) async throws {
        let name = bridge.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let nets = try await db.read { db in
            try Network.filter(Column("bridge") == name).fetchAll(db)
        }
        for net in nets {
            _ = try await delete(id: net.id, db: db)
        }
    }
}
