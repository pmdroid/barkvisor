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
        if let dns = params.dnsServer, !dns.isEmpty {
            try NetworkIntentResolver.requireGuestDNS(dns, mode: mode)
        }
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
    ///
    /// The whole read-validate-write cycle runs inside one write transaction
    /// (BV-03 / #634). A separate `db.read` would leave a window in which a
    /// Workload could attach with port forwards between the attached-Workload
    /// check and the mutation, persisting a network/Workload pair that can no
    /// longer launch. GRDB serializes writers, so holding the write lock is
    /// what makes concurrent attachment versus mode change resolve to one
    /// winner instead of a half-applied state.
    public static func update(
        _ params: UpdateNetworkParams,
        db: DatabasePool,
    ) async throws -> Network {
        try await db.write { db in
            guard var network = try Network.fetchOne(db, key: params.id) else {
                throw BarkVisorError.notFound()
            }
            guard !network.isDefault else {
                throw BarkVisorError.forbidden("The default \(network.mode) network cannot be modified")
            }

            let previousMode = network.mode
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
            if let dns = network.dnsServer, !dns.isEmpty {
                try NetworkIntentResolver.requireGuestDNS(dns, mode: mode)
            }
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
                let conflict = try Network
                    .filter(Column("bridge") == bridge)
                    .filter(Column("id") != params.id)
                    .fetchOne(db)
                try HostBridgeFactsService.requireUnusedBridgedInterface(bridge, occupiedBy: conflict)
            }

            // A mode that still publishes hostfwd is a widening move: attached
            // Workloads stay launchable. Only a mode change that withdraws
            // port forwards needs the attached-Workload check, so metadata-only
            // edits on a network that already has stranded forwards still work.
            if network.mode != previousMode {
                try requireModeChangeKeepsAttachedWorkloadsLaunchable(
                    networkID: params.id, proposedMode: mode, db: db,
                )
            }

            try network.update(db)
            return network
        }
    }

    /// Attached Workloads keep their own port-forward rules; a mode change
    /// cannot rewrite them. Reject a move to a mode without `hostfwd` while any
    /// attached Workload still has forwards, because otherwise the row pair
    /// persists a combination that `QEMUBuilder` refuses at next start, and
    /// `PortRegistry.claims` silently stops counting the Workload even though a
    /// running QEMU still holds the socket.
    private static func requireModeChangeKeepsAttachedWorkloadsLaunchable(
        networkID: String,
        proposedMode: NetworkMode,
        db: Database,
    ) throws {
        guard !proposedMode.allowsPortForwards else { return }
        let attached = try VM.filter(Column("networkId") == networkID).fetchAll(db)
        let stranded = attached.filter { !$0.decodedPortForwards.isEmpty }
        guard !stranded.isEmpty else { return }
        let names = stranded.map { "\"\($0.name)\"" }.sorted().joined(separator: ", ")
        throw BarkVisorError.conflict(
            "Cannot change network mode to '\(proposedMode.rawValue)': "
                + "\(stranded.count) attached Workload(s) still use port forwards (\(names)). "
                + "Port forwards require NAT. Remove their port forwards or move them to "
                + "another network first.",
        )
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
