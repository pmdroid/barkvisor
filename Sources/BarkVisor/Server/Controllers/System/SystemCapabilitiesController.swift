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

    /// Host platform feature matrix — single source: PlatformCapabilities.
    static func currentCapabilities() -> SystemCapabilitiesResponse {
        SystemCapabilitiesResponse(
            platform: PlatformHost.platformName,
            supportsBridgedNetworking: PlatformCapabilities.supportsBridgedNetworking,
            supportsManagedBridgeDaemon: PlatformCapabilities.supportsManagedBridgeDaemon,
            supportsUSBPassthrough: PlatformCapabilities.supportsUSBPassthrough,
            supportsInAppUpdate: PlatformCapabilities.supportsInAppUpdate,
            accelerator: PlatformCapabilities.accelerator,
            hostArch: hostArchitecture(),
        )
    }

    private static func hostArchitecture() -> String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 256) {
                String(cString: $0)
            }
        }
        switch machine {
        case "arm64", "aarch64": return "arm64"
        case "x86_64", "amd64": return "x86_64"
        default: return machine
        }
    }
}
