import BarkVisorCore
import Vapor

/// JWT-protected host inventory (PAS-42).
///
/// Returns the same `HostInventory` snapshot used by capabilities and
/// diagnostics. Wave 0 keeps `AgentInfo.role` as `colocal`; member/controller
/// roles stay Wave 1.
struct AgentInventoryController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.get("api", "agent", "inventory", use: getInventory)
    }

    @Sendable
    func getInventory(req: Vapor.Request) async throws -> HostInventory {
        let displayName = try await req.db.read { try DeviceNameSettings.resolved(from: $0) }
        return HostInventoryService.snapshot(displayName: displayName)
    }
}
