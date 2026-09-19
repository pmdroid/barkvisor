import Foundation

/// A short-lived, single-use ticket store for WebSocket/SSE authentication.
///
/// Instead of passing long-lived JWT tokens in URL query parameters (which leak
/// into browser history, server logs, and proxy logs), clients exchange their
/// JWT for a single-use ticket via an authenticated POST endpoint, then pass
/// only the ticket in the URL.
public actor WebSocketTicketStore {
    public struct TicketEntry: Sendable {
        public let userID: String
        public let username: String
        public let targetVMID: String?
        public let targetHostID: String?
        public let osUser: String?
        public let expiresAt: Date

        public init(
            userID: String,
            username: String,
            targetVMID: String?,
            targetHostID: String? = nil,
            osUser: String? = nil,
            expiresAt: Date,
        ) {
            self.userID = userID
            self.username = username
            self.targetVMID = targetVMID
            self.targetHostID = targetHostID
            self.osUser = osUser
            self.expiresAt = expiresAt
        }
    }

    private var tickets: [String: TicketEntry] = [:]
    private var pruneTask: Task<Void, Never>?
    private let now: @Sendable () -> Date

    public static let shared: WebSocketTicketStore = {
        let store = WebSocketTicketStore()
        Task { await store.startPruning() }
        return store
    }()

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    private func startPruning() {
        guard pruneTask == nil else { return }
        pruneTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await self?.pruneExpired()
            }
        }
    }

    /// Create a short-lived single-use ticket for the given user, optionally scoped to a specific VM.
    /// Tickets expire after 30 seconds.
    public func createTicket(
        forUserID userID: String,
        username: String,
        targetVMID: String? = nil,
        targetHostID: String? = nil,
        osUser: String? = nil,
    ) -> String {
        let ticket = UUID().uuidString
        let entry = TicketEntry(
            userID: userID,
            username: username,
            targetVMID: targetVMID,
            targetHostID: targetHostID,
            osUser: osUser,
            expiresAt: now().addingTimeInterval(30),
        )
        tickets[ticket] = entry
        return ticket
    }

    /// Spend-on-use on the owner Device (PAS-237). Home must not call this
    /// with a Device ticket — see `StreamTicketPolicy.requirePassThroughDeviceTicket`.
    /// The ticket is always removed (single-use), even if expired or wrong VM.
    public func validateTicket(_ ticket: String, forVMID vmID: String) -> (
        userID: String, username: String,
    )? {
        guard let entry = tickets.removeValue(forKey: ticket) else {
            return nil
        }
        guard entry.expiresAt > now() else { return nil }
        guard entry.targetVMID == vmID, entry.targetHostID == nil, entry.osUser == nil else {
            return nil
        }
        return (userID: entry.userID, username: entry.username)
    }

    /// Validate and consume a ticket (non-VM-scoped SSE: logs, image progress, tasks).
    /// Diagnostic bundle download is Bearer/API-key, not a Device ticket.
    /// The ticket is always removed (single-use), even if expired or VM-scoped.
    public func validateTicket(_ ticket: String) -> (userID: String, username: String)? {
        guard let entry = tickets.removeValue(forKey: ticket) else {
            return nil
        }
        guard entry.expiresAt > now() else { return nil }
        guard entry.targetVMID == nil, entry.targetHostID == nil, entry.osUser == nil else {
            return nil
        }
        return (userID: entry.userID, username: entry.username)
    }

    public func validateTicket(_ ticket: String, hostID: String) -> (
        userID: String, username: String, osUser: String,
    )? {
        guard let entry = tickets.removeValue(forKey: ticket) else {
            return nil
        }
        guard entry.expiresAt > now() else { return nil }
        guard entry.targetVMID == nil, entry.targetHostID == hostID, let osUser = entry.osUser,
              !osUser.isEmpty
        else { return nil }
        return (userID: entry.userID, username: entry.username, osUser: osUser)
    }

    private func pruneExpired() {
        let now = now()
        tickets = tickets.filter { $0.value.expiresAt > now }
    }
}
