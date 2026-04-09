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
        public let expiresAt: Date

        public init(userID: String, username: String, targetVMID: String?, expiresAt: Date) {
            self.userID = userID
            self.username = username
            self.targetVMID = targetVMID
            self.expiresAt = expiresAt
        }
    }

    private var tickets: [String: TicketEntry] = [:]
    private var pruneTask: Task<Void, Never>?

    public static let shared: WebSocketTicketStore = {
        let store = WebSocketTicketStore()
        Task { await store.startPruning() }
        return store
    }()

    private init() {}

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
    public func createTicket(forUserID userID: String, username: String, targetVMID: String? = nil)
        -> String {
        let ticket = UUID().uuidString
        let entry = TicketEntry(
            userID: userID,
            username: username,
            targetVMID: targetVMID,
            expiresAt: Date().addingTimeInterval(30),
        )
        tickets[ticket] = entry
        return ticket
    }

    /// Validate and consume a ticket, requiring it to be scoped to the given VM ID.
    /// The ticket is always removed (single-use), even if expired or wrong VM.
    public func validateTicket(_ ticket: String, forVMID vmID: String) -> (
        userID: String, username: String,
    )? {
        guard let entry = tickets.removeValue(forKey: ticket) else {
            return nil
        }
        guard entry.expiresAt > Date() else { return nil }
        guard entry.targetVMID == vmID else { return nil }
        return (userID: entry.userID, username: entry.username)
    }

    /// Validate and consume a ticket (non-VM-scoped endpoints like SSE logs, diagnostics).
    /// The ticket is always removed (single-use), even if expired.
    public func validateTicket(_ ticket: String) -> (userID: String, username: String)? {
        guard let entry = tickets.removeValue(forKey: ticket) else {
            return nil
        }
        guard entry.expiresAt > Date() else { return nil }
        return (userID: entry.userID, username: entry.username)
    }

    private func pruneExpired() {
        let now = Date()
        tickets = tickets.filter { $0.value.expiresAt > now }
    }
}
