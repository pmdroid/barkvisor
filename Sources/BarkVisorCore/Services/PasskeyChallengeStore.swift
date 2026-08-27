import Foundation

public actor PasskeyChallengeStore {
    public enum Kind: String, Sendable {
        case register
        case login
    }

    public struct Entry: Sendable {
        public let kind: Kind
        public let challenge: [UInt8]
        public let rpId: String
        public let origin: String
        public let userId: String?
        public let name: String?
        public let expiresAt: Date
    }

    public static let shared = PasskeyChallengeStore()

    private var sessions: [String: Entry] = [:]

    public init() {}

    public func store(
        kind: Kind,
        challenge: [UInt8],
        rpId: String,
        origin: String,
        userId: String?,
        name: String?,
        ttl: TimeInterval,
        now: Date = Date(),
    ) -> String {
        prune(now: now)
        let id = UUID().uuidString
        sessions[id] = Entry(
            kind: kind,
            challenge: challenge,
            rpId: rpId,
            origin: origin,
            userId: userId,
            name: name,
            expiresAt: now.addingTimeInterval(ttl),
        )
        return id
    }

    public func consume(_ sessionId: String, now: Date = Date()) -> Entry? {
        prune(now: now)
        guard let entry = sessions.removeValue(forKey: sessionId) else { return nil }
        guard entry.expiresAt > now else { return nil }
        return entry
    }

    public func peek(_ sessionId: String) -> Entry? {
        sessions[sessionId]
    }

    private func prune(now: Date) {
        sessions = sessions.filter { $0.value.expiresAt > now }
    }
}
