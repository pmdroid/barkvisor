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

    /// macOS socket_vmnet install/start/stop/remove. Linux host-net apply is #378.
    private static func requireManagedBridgeDaemon() throws {
        try PlatformCapabilities.requireManagedBridgeDaemon()
    }

    @Sendable
    func installBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            return try Self.linuxApply(req: req, defaultAction: .apply)
        }
        try Self.requireManagedBridgeDaemon()

        let body = try req.content.decode(BridgeRequest.self)
        guard let iface = body.interface, !iface.isEmpty else {
            throw Abort(.badRequest, reason: "Interface is required")
        }

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
        if PlatformCapabilities.supportsHostBridgeManagement {
            throw BarkVisorError.badRequest(
                "Linux host bridges use apply and revert, not start or stop.",
            )
        }
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
        if PlatformCapabilities.supportsHostBridgeManagement {
            throw BarkVisorError.badRequest(
                "Linux host bridges use apply and revert, not start or stop.",
            )
        }
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
        if PlatformCapabilities.supportsHostBridgeManagement {
            return try Self.linuxApply(req: req, defaultAction: .revert)
        }
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

    private static func linuxApply(
        req: Vapor.Request,
        defaultAction: LinuxHostBridgeApplyAction,
    ) throws -> BridgeActionResponse {
        try PlatformCapabilities.requireHostMutation()
        let body = (try? req.content.decode(BridgeRequest.self)) ?? BridgeRequest()
        let action = parseAction(body, default: defaultAction)
        let addressing: LinuxHostBridgeAddressing =
            body.addressing == LinuxHostBridgeAddressing.staticIP.rawValue ? .staticIP : .dhcp
        let nic = body.interface
            ?? req.parameters.get("interface").flatMap { $0 == HostBridgeFactsService.suggestedBridgeName ? nil : $0 }
        let request = LinuxHostBridgeApplyRequest(
            action: action,
            bridge: body.bridge ?? HostBridgeFactsService.suggestedBridgeName,
            nic: nic,
            addressing: addressing,
            address: body.address,
            gateway: body.gateway,
            dns: body.dns ?? [],
            confirm: body.confirm == true,
            deleteBridge: body.deleteBridge == true,
        )
        let result = try LinuxHostBridgeApplyLive.run(request: request)
        if result.applied {
            AuditService.log(
                action: action == .revert ? "host-bridge.revert" : "host-bridge.apply",
                resourceType: "host-bridge",
                resourceId: request.bridge,
                resourceName: request.bridge,
                req: req,
            )
        }
        return BridgeActionResponse(
            success: result.success,
            message: result.message,
            applied: result.applied,
            needsConfirm: result.needsConfirm,
            backend: result.backend,
            changes: result.changes,
            warnings: result.warnings,
            commands: result.commands,
        )
    }

    private static func parseAction(
        _ body: BridgeRequest,
        default defaultAction: LinuxHostBridgeApplyAction,
    ) -> LinuxHostBridgeApplyAction {
        if body.dryRun == true { return .dryRun }
        if let raw = body.action?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return LinuxHostBridgeApplyAction(rawValue: raw) ?? defaultAction
        }
        return defaultAction
    }
}
