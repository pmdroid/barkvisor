import BarkVisorCore
import Vapor

/// When `requireTailnetForRemote` is on, JWT/login API from a public address
/// is refused. LAN, loopback, and CGNAT `100.64.0.0/10` stay allowed (PAS-89).
struct RemoteAccessGateMiddleware: AsyncMiddleware {
    func respond(
        to request: Vapor.Request,
        chainingTo next: any AsyncResponder,
    ) async throws -> Vapor.Response {
        let path = request.url.path
        if isExempt(path) {
            return try await next.respond(to: request)
        }
        let require = try await request.db.read { db in
            try RemoteAccessSettings.load(from: db).requireTailnetForRemote
        }
        guard require else {
            return try await next.respond(to: request)
        }
        let ip = request.peerAddress?.ipAddress ?? request.remoteAddress?.ipAddress
        guard RemoteAccessSettings.allowsPeer(ip) else {
            throw BarkVisorError.forbidden(
                "Remote access requires Tailscale (or a LAN address). "
                    + "Install Tailscale on this Device and the client, or turn off "
                    + "require-tailnet in Settings → Home.",
            )
        }
        return try await next.respond(to: request)
    }

    private func isExempt(_ path: String) -> Bool {
        if !path.hasPrefix("/api/") { return true }
        switch path {
        case "/api/health",
             "/api/openapi.yaml",
             "/api/contract",
             "/api/workloadspec.schema.json",
             "/api/system/capabilities":
            return true
        default:
            return false
        }
    }
}
