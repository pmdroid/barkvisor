import BarkVisorCore
import Foundation
import GRDB
import Vapor

struct SystemBridgeController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let system = routes.grouped("api", "system")
        system.get("bridges", use: listBridges)
        system.post("bridges", use: installBridge)
        system.post("bridges", ":interface", "start", use: startBridge)
        system.post("bridges", ":interface", "stop", use: stopBridge)
        system.delete("bridges", ":interface", use: removeBridge)
    }

    @Sendable
    func listBridges(req: Vapor.Request) async throws -> [BridgeInfo] {
        let records = try await req.db.read { db in
            try BridgeRecord.fetchAll(db)
        }
        return records.map { r in
            BridgeInfo(
                interface: r.interface,
                socketPath: r.socketPath,
                plistExists: r.plistExists,
                daemonRunning: r.daemonRunning,
                status: r.status,
            )
        }
    }

    /// install/start/stop/remove require the macOS managed bridge daemon (XPC helper).
    /// Product bridged networking on Linux uses host bridges without these lifecycle routes.
    private static func requireManagedBridgeDaemon() throws {
        guard PrivilegeService.isManagedBridgeDaemonSupported else {
            throw Abort(
                .notImplemented,
                reason: "Managed bridge daemon lifecycle is not supported on this platform. "
                    + "On Linux, create a host bridge (e.g. br0) with ip/netplan, then attach "
                    + "VMs via a Bridged network record.",
            )
        }
    }

    @Sendable
    func installBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        try Self.requireManagedBridgeDaemon()

        let body = try req.content.decode(BridgeRequest.self)
        let iface = body.interface

        // Validate interface exists on the host
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        // Check if a bridge already exists for this interface
        let existingBridge = try await req.db.read { db in
            try BridgeRecord.filter(Column("interface") == iface).fetchOne(db)
        }
        if let existingBridge, existingBridge.status != "not_configured" {
            throw Abort(
                .conflict,
                reason: "Bridge already exists for interface '\(iface)' (status: \(existingBridge.status))",
            )
        }

        // Delegate to privilege service (XPC helper on macOS)
        do {
            try await PrivilegeService.shared.installBridge(interface: iface)
            // Immediate sync so DB reflects the change
            let db = req.db
            Task { await BridgeSyncService.syncOnce(db: db) }

            // Auto-create a bridged network if none exists for this interface
            let existingNetwork = try await req.db.read { db in
                try Network.filter(Column("bridge") == iface).fetchOne(db)
            }
            if existingNetwork == nil {
                let network = Network(
                    id: UUID().uuidString,
                    name: "Bridged (\(iface))",
                    mode: "bridged",
                    bridge: iface,
                    macAddress: nil,
                    dnsServer: nil,
                    autoCreated: true,
                    isDefault: false,
                )
                try await req.db.write { db in
                    try network.insert(db)
                }
                AuditService.log(
                    action: "network.create", resourceType: "network", resourceId: network.id,
                    resourceName: network.name, req: req,
                )
            }

            return BridgeActionResponse(success: true, message: "Bridge installed for \(iface)")
        } catch let error as BarkVisorError {
            throw error
        } catch {
            Log.server.error("Failed to install bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to install bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func startBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        try Self.requireManagedBridgeDaemon()

        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await PrivilegeService.shared.startBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge started for \(iface)")
        } catch let error as BarkVisorError {
            throw error
        } catch {
            Log.server.error("Failed to start bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to start bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func stopBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        try Self.requireManagedBridgeDaemon()

        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await PrivilegeService.shared.stopBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge stopped for \(iface)")
        } catch let error as BarkVisorError {
            throw error
        } catch {
            Log.server.error("Failed to stop bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to stop bridge: \(error.localizedDescription)",
            )
        }
    }

    @Sendable
    func removeBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        try Self.requireManagedBridgeDaemon()

        guard let iface = req.parameters.get("interface") else {
            throw Abort(.badRequest, reason: "Missing interface parameter")
        }
        guard HostInfoService.interfaceExists(iface) else {
            throw Abort(.badRequest, reason: "Interface '\(iface)' not found on this host")
        }

        do {
            try await PrivilegeService.shared.removeBridge(interface: iface)
            await BridgeSyncService.syncOnce(db: req.db)
            return BridgeActionResponse(success: true, message: "Bridge removed for \(iface)")
        } catch let error as BarkVisorError {
            throw error
        } catch {
            Log.server.error("Failed to remove bridge for \(iface): \(error)")
            throw Abort(
                .internalServerError, reason: "Failed to remove bridge: \(error.localizedDescription)",
            )
        }
    }
}
