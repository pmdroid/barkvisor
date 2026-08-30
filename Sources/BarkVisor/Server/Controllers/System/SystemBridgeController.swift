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

    @Sendable
    func installBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            return try Self.linuxApply(req: req, defaultAction: .apply)
        }
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return try Self.macHostApply(req: req, defaultAction: .apply)
        }
        try PlatformCapabilities.requireHostMutation()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
    }

    @Sendable
    func startBridge(req _: Vapor.Request) async throws -> BridgeActionResponse {
        throw BarkVisorError.badRequest(
            "Host bridges use apply and revert, not start or stop.",
        )
    }

    @Sendable
    func stopBridge(req _: Vapor.Request) async throws -> BridgeActionResponse {
        throw BarkVisorError.badRequest(
            "Host bridges use apply and revert, not start or stop.",
        )
    }

    @Sendable
    func removeBridge(req: Vapor.Request) async throws -> BridgeActionResponse {
        if PlatformCapabilities.supportsHostBridgeManagement {
            return try Self.linuxApply(req: req, defaultAction: .revert)
        }
        if PlatformCapabilities.supportsManagedBridgeDaemon {
            return try Self.macHostApply(req: req, defaultAction: .revert)
        }
        try PlatformCapabilities.requireHostMutation()
        throw BarkVisorError.unsupportedFeature(.managedBridgeDaemon)
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

    private static func macHostApply(
        req: Vapor.Request,
        defaultAction: MacHostBridgeApplyAction,
    ) throws -> BridgeActionResponse {
        try PlatformCapabilities.requireHostMutation()
        let body = (try? req.content.decode(BridgeRequest.self)) ?? BridgeRequest()
        let action = parseMacAction(body, default: defaultAction)
        let addressing: MacHostBridgeAddressing =
            body.addressing == MacHostBridgeAddressing.staticIP.rawValue ? .staticIP : .dhcp
        let nic = body.interface
            ?? req.parameters.get("interface").flatMap { $0 == HostBridgeFactsService.suggestedBridgeName ? nil : $0 }
        let request = MacHostBridgeApplyRequest(
            action: action,
            service: body.bridge,
            nic: nic,
            addressing: addressing,
            address: body.address,
            gateway: body.gateway,
            dns: body.dns ?? [],
            confirm: body.confirm == true,
        )
        let result = try MacHostBridgeApplyLive.run(request: request)
        if result.applied {
            AuditService.log(
                action: action == .revert ? "host-bridge.revert" : "host-bridge.apply",
                resourceType: "host-bridge",
                resourceId: request.service ?? request.nic ?? MacHostBridgeApply.backendName,
                resourceName: request.service ?? "Device address",
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

    private static func parseMacAction(
        _ body: BridgeRequest,
        default defaultAction: MacHostBridgeApplyAction,
    ) -> MacHostBridgeApplyAction {
        if body.dryRun == true { return .dryRun }
        if let raw = body.action?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return MacHostBridgeApplyAction(rawValue: raw) ?? defaultAction
        }
        return defaultAction
    }
}
