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

    /// Host platform feature matrix — single source: PlatformCapabilities + GuestProfiles.
    static func currentCapabilities() -> SystemCapabilitiesResponse {
        SystemCapabilitiesResponse(
            platform: PlatformHost.platformName,
            supportsBridgedNetworking: PlatformCapabilities.supportsBridgedNetworking,
            supportsManagedBridgeDaemon: PlatformCapabilities.supportsManagedBridgeDaemon,
            supportsUSBPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            supportsInAppUpdate: PlatformCapabilities.supportsInAppUpdate,
            accelerator: PlatformCapabilities.accelerator,
            hostArch: PlatformCapabilities.hostArch,
            hostCpuCount: PlatformHost.cpuCount,
            guestTypes: GuestProfiles.all.map {
                GuestTypeInfo(
                    id: $0.id,
                    arch: $0.arch,
                    machine: $0.machine,
                    osFamily: $0.osFamily,
                    qemuBinary: $0.qemuBinaryName,
                )
            },
        )
    }
}
