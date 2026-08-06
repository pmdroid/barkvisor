import BarkVisorCore
import Foundation
import Vapor

enum SystemCapabilitiesController {
    /// Public endpoint (no JWT) so setup wizard can gate bridge step before login.
    static func registerPublicRoutes(_ routes: any RoutesBuilder) {
        routes.get("api", "system", "capabilities", use: getCapabilities)
    }

    @Sendable
    static func getCapabilities(req: Vapor.Request) async throws -> SystemCapabilitiesResponse {
        currentCapabilities()
    }

    /// Host platform feature matrix — projected from `HostInventoryService.snapshot()`.
    /// Keeps capabilities aligned with the multi-host-ready inventory document.
    static func currentCapabilities() -> SystemCapabilitiesResponse {
        let inv = HostInventoryService.snapshot()
        return SystemCapabilitiesResponse(
            platform: inv.platform.os,
            supportsBridgedNetworking: inv.virtualization.features.bridgedNetworking,
            supportsManagedBridgeDaemon: inv.virtualization.features.managedBridgeDaemon,
            supportsUSBPassthrough: inv.virtualization.features.usbPassthrough,
            supportsInAppUpdate: inv.virtualization.features.inAppUpdate,
            accelerator: inv.virtualization.accelerator,
            hostArch: inv.platform.arch,
            hostCpuCount: inv.resources.cpuCount,
            guestTypes: inv.guestTypes.map {
                GuestTypeInfo(
                    id: $0.id,
                    arch: $0.arch,
                    machine: $0.machine,
                    osFamily: $0.osFamily,
                    qemuBinary: $0.qemuBinary,
                )
            },
        )
    }
}
