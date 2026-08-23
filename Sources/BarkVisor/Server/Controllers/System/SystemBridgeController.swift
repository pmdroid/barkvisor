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
        if !PlatformCapabilities.supportsManagedBridgeDaemon {
            return HostBridgeFactsService.hostBridgeInfos(from: HostBridgeFactsService.probe())
                .map(Self.bridgeInfo(from:))
        }
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

    private static func bridgeInfo(from dto: BridgeStateDTO) -> BridgeInfo {
        BridgeInfo(
            interface: dto.interface,
            socketPath: dto.socketPath,
            plistExists: dto.plistExists,
            daemonRunning: dto.daemonRunning,
            status: dto.status,
        )
    }

    /// install/start/stop/remove require a managed bridge daemon (unsupported;
    /// macOS uses operator-managed Homebrew socket_vmnet).
    /// Product bridged networking on Linux uses host bridges without these lifecycle routes.
    private static func requireManagedBridgeDaemon() throws {
        try PlatformCapabilities.requireManagedBridgeDaemon()
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

        // PrivilegeService on macOS is probe-only (PAS-294); this route still 501s.
        do {
            try await PrivilegeService.shared.installBridge(interface: iface)
            let db = req.db
            Task { await BridgeSyncService.syncOnce(db: db) }

            let before = try await req.db.read { db in
                try Network.filter(Column("bridge") == iface).fetchOne(db)
            }
            let network = try await NetworkService.ensureBridgedNetwork(for: iface, db: req.db)
            if before == nil {
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
