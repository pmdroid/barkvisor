import Foundation

/// One stream credential policy for console / VNC (PAS-237).
///
/// Device `ticket` is one-use and spent on the owner Device. Home never spends
/// that value — it checks UUID shape and forwards it. Browser WebSockets cannot
/// set `Authorization`, so a member tunnel also carries a Home-minted
/// `session=` (spent on Home, Workload-scoped). noVNC rewrites `ticket` to
/// `token`; hop rewrite turns that back into `ticket` before the Device.
///
/// SPA and iOS only adapt transport (`ticket` / `session` query names stay).
public enum StreamTicketPolicy {
    public static let ticketQueryName = "ticket"
    public static let tokenRewriteQueryName = "token"
    public static let sessionQueryName = "session"
    public static let mintPath = "/api/auth/ws-ticket"
    public static let missingTicketReason =
        "Missing ticket. Use POST /api/auth/ws-ticket to obtain one."
    public static let invalidTicketReason = "Invalid ticket"
    public static let expiredTicketReason = "Invalid or expired ticket"
    public static let expiredSessionReason = "Invalid or expired session"

    /// Where a stream request is authenticated.
    public enum Site: Equatable, Sendable {
        /// Owner Device spends `ticket` / `token` (one-use, Workload-scoped).
        case ownerDevice
        /// Home tunnel: spend Home `session`; pass Device ticket through unspent.
        case homeTunnel
        /// Other JWT routes (SSE, logs): unscoped `ticket` spend if present.
        case other
    }

    public static func site(path: String) -> Site {
        if isHomeConsoleTunnel(path) { return .homeTunnel }
        if isOwnerDeviceStream(path) { return .ownerDevice }
        return .other
    }

    /// `/api/home/devices/{id}/v1/vms/{vmId}/vnc|console`
    public static func isHomeConsoleTunnel(_ path: String) -> Bool {
        guard path.contains("/api/home/devices/") else { return false }
        return path.hasSuffix("/vnc") || path.hasSuffix("/console")
    }

    /// `/api/vms/{id}/vnc|console` on the owner Device (and the agent hop).
    public static func isOwnerDeviceStream(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 4, parts[0] == "api", parts[1] == "vms" else { return false }
        return parts[3] == "vnc" || parts[3] == "console"
    }

    public static func queryItems(from raw: String?) -> [URLQueryItem] {
        guard let raw, !raw.isEmpty else { return [] }
        var parts = URLComponents()
        parts.percentEncodedQuery = raw
        return parts.queryItems ?? []
    }

    public static func firstValue(_ items: [URLQueryItem], name: String) -> String? {
        items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Device ticket: `ticket=` or noVNC's `token=` rewrite.
    public static func deviceTicket(in items: [URLQueryItem]) -> String? {
        firstValue(items, name: ticketQueryName) ?? firstValue(items, name: tokenRewriteQueryName)
    }

    public static func deviceTicket(fromQuery query: String?) -> String? {
        deviceTicket(in: queryItems(from: query))
    }

    public static func homeSession(in items: [URLQueryItem]) -> String? {
        firstValue(items, name: sessionQueryName)
    }

    public static func homeSession(fromQuery query: String?) -> String? {
        homeSession(in: queryItems(from: query))
    }

    /// Home / intermediary: UUID shape only. Never consume the Device ticket.
    public static func requirePassThroughDeviceTicket(_ ticket: String?) throws {
        guard let ticket, !ticket.isEmpty else {
            throw BarkVisorError.unauthorized(missingTicketReason)
        }
        guard UUID(uuidString: ticket) != nil else {
            throw BarkVisorError.unauthorized(invalidTicketReason)
        }
    }

    /// Member tunnels need a Home-minted `session=`. This Device does not.
    public static func needsHomeSession(isSelfDevice: Bool) -> Bool {
        !isSelfDevice
    }

    public static func clientQueryItems(ticket: String, session: String?) -> [URLQueryItem] {
        var items = [URLQueryItem(name: ticketQueryName, value: ticket)]
        if let session, !session.isEmpty {
            items.append(URLQueryItem(name: sessionQueryName, value: session))
        }
        return items
    }

    /// Client socket query: `ticket=` plus optional Home `session=`. Never JWT.
    public static func clientQuery(ticket: String, session: String?) -> String {
        encodedQuery(clientQueryItems(ticket: ticket, session: session)) ?? ""
    }

    /// Hop rewrite: Device ticket only, name `ticket=`. Drop Home `session=`.
    public static func hopQuery(from query: String?) -> String? {
        guard let ticket = deviceTicket(fromQuery: query) else { return nil }
        return encodedQuery([URLQueryItem(name: ticketQueryName, value: ticket)])
    }

    public static func mintBody(workloadID: String) -> [String: String] {
        ["vmID": workloadID]
    }

    private static func encodedQuery(_ items: [URLQueryItem]) -> String? {
        var parts = URLComponents()
        parts.queryItems = items
        return parts.percentEncodedQuery
    }
}
