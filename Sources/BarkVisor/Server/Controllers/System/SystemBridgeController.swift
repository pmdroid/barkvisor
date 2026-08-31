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
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            let response = try Self.macHostApply(req: req, defaultAction: .apply)
            if response.applied == true {
                await Self.syncMacBridgedNetwork(req: req, body: (try? req.content.decode(BridgeRequest.self)))
            }
            return response
        }
        try Self.requireManagedBridgeDaemon()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
    }

    @Sendable
    func startBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            throw BarkVisorError.badRequest(
                "Linux host bridges use apply and revert, not start or stop.",
            )
        }
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return try Self.macHostApply(req: req, defaultAction: .apply)
        }
        try Self.requireManagedBridgeDaemon()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
    }

    @Sendable
    func stopBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            throw BarkVisorError.badRequest(
                "Linux host bridges use apply and revert, not start or stop.",
            )
        }
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return try Self.macHostApply(req: req, defaultAction: .revert)
        }
        try Self.requireManagedBridgeDaemon()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
    }

    @Sendable
    func removeBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            return try Self.linuxApply(req: req, defaultAction: .revert)
        }
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return try Self.macHostApply(req: req, defaultAction: .revert)
        }
        try Self.requireManagedBridgeDaemon()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
    }

    private static func linuxApply(
        req: Vapor.Request,
        defaultAction: LinuxHostBridgeApplyAction,
    ) throws -> BridgeActionResponse {
        try PlatformCapabilities.requireHostMutation()
        let body = (try? req.content.decode(BridgeRequest.self)) ?? BridgeRequest()
        let request = try bridgeApplyRequest(from: body, req: req, defaultAction: defaultAction)
        let result = try LinuxHostBridgeApplyLive.run(request: request)
        if result.applied {
            AuditService.log(
                action: request.action == .revert ? "host-bridge.revert" : "host-bridge.apply",
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

    private static func macHostApply(
        req: Vapor.Request,
        defaultAction: LinuxHostBridgeApplyAction,
    ) throws -> BridgeActionResponse {
        try PlatformCapabilities.requireHostMutation()
        #if os(macOS)
            let body = (try? req.content.decode(BridgeRequest.self)) ?? BridgeRequest()
            let request = try bridgeApplyRequest(from: body, req: req, defaultAction: defaultAction)
            let result = try MacHostBridgeApplyLive.run(request: request)
            if result.applied {
                AuditService.log(
                    action: request.action == .revert ? "host-bridge.revert" : "host-bridge.apply",
                    resourceType: "host-bridge",
                    resourceId: request.nic ?? "socket_vmnet",
                    resourceName: request.nic ?? "socket_vmnet",
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
        #else
            throw BarkVisorError.forbidden("macOS host network apply runs on a macOS Device.")
        #endif
    }

    private static func bridgeApplyRequest(
        from body: BridgeRequest,
        req: Vapor.Request,
        defaultAction: LinuxHostBridgeApplyAction,
    ) throws -> LinuxHostBridgeApplyRequest {
        let action = parseAction(body, default: defaultAction)
        let addressing: LinuxHostBridgeAddressing =
            body.addressing == LinuxHostBridgeAddressing.staticIP.rawValue ? .staticIP : .dhcp
        let nic = body.interface
            ?? req.parameters.get("interface").flatMap { $0 == HostBridgeFactsService.suggestedBridgeName ? nil : $0 }
        let addresses = try parseAddressApplyEntries(body.addresses)
        return LinuxHostBridgeApplyRequest(
            action: action,
            bridge: body.bridge ?? HostBridgeFactsService.suggestedBridgeName,
            nic: nic,
            addressing: addressing,
            address: body.address,
            gateway: body.gateway,
            dns: body.dns ?? [],
            addresses: addresses,
            confirm: body.confirm == true,
            deleteBridge: body.deleteBridge == true,
        )
    }

    private static func parseAddressApplyEntries(
        _ rows: [BridgeAddressRequest]?,
    ) throws -> [HostInterfaceAddressApplyEntry] {
        guard let rows, !rows.isEmpty else { return [] }
        return try rows.map { row in
            guard let kind = HostInterfaceAddressApplyKind(rawValue: row.kind) else {
                throw BarkVisorError.badRequest(
                    "addresses[].kind must be dhcp, static, or alias (got \"\(row.kind)\")",
                )
            }
            return HostInterfaceAddressApplyEntry(
                kind: kind,
                cidr: row.cidr,
                gateway: row.gateway,
                dns: row.dns,
            )
        }
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

    private static func socketVmnetApply(
        req: Vapor.Request,
        defaultAction: SocketVmnetApplyAction,
    ) async throws -> BridgeActionResponse {
        try PlatformCapabilities.requireManagedBridgeDaemon()
        let body = (try? req.content.decode(BridgeRequest.self)) ?? BridgeRequest()
        let action = parseSocketAction(body, default: defaultAction)
        let iface = body.interface ?? req.parameters.get("interface")
        let result = try SocketVmnetApplyLive.run(
            request: SocketVmnetApplyRequest(action: action, interface: iface),
        )
        if result.applied {
            await BridgeSyncService.syncOnce(db: req.db)
            if action == .setup || action == .start, let name = iface, !name.isEmpty {
                let before = try await req.db.read { db in
                    try Network.filter(Column("bridge") == name).fetchOne(db)
                }
                let network = try await NetworkService.ensureBridgedNetwork(for: name, db: req.db)
                if before == nil {
                    AuditService.log(
                        action: "network.create",
                        resourceType: "network",
                        resourceId: network.id,
                        resourceName: network.name,
                        req: req,
                    )
                }
            }
            AuditService.log(
                action: "socket-vmnet.\(action.rawValue)",
                resourceType: "socket-vmnet",
                resourceId: iface ?? SocketVmnetLaunchd.homebrewServiceLabel,
                resourceName: iface ?? "socket_vmnet",
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

    private static func syncMacBridgedNetwork(req: Vapor.Request, body: BridgeRequest?) async {
        let iface = body?.interface ?? req.parameters.get("interface")
        guard let name = iface, !name.isEmpty else { return }
        await BridgeSyncService.syncOnce(db: req.db)
        let before = try? await req.db.read { db in
            try Network.filter(Column("bridge") == name).fetchOne(db)
        }
        if let network = try? await NetworkService.ensureBridgedNetwork(for: name, db: req.db),
           before == nil {
            AuditService.log(
                action: "network.create",
                resourceType: "network",
                resourceId: network.id,
                resourceName: network.name,
                req: req,
            )
        }
    }

    private static func parseSocketAction(
        _ body: BridgeRequest,
        default defaultAction: SocketVmnetApplyAction,
    ) -> SocketVmnetApplyAction {
        if let raw = body.action?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return SocketVmnetApplyAction(rawValue: raw) ?? defaultAction
        }
        return defaultAction
    }
}
