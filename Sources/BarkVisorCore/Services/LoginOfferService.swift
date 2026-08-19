import Foundation
import GRDB
import JWTKit

public enum LoginOfferService {
    public static let defaultTTL: TimeInterval = 3 * 60

    public struct IssueInput: Sendable {
        public var userId: String
        public var advertisedHost: String?
        public var advertisedHosts: [String]
        public var port: Int
        public var ttl: TimeInterval
        public var now: Date

        public init(
            userId: String,
            advertisedHost: String? = nil,
            advertisedHosts: [String] = PairingAddresses.advertisedIPv4(),
            port: Int = Config.port,
            ttl: TimeInterval = LoginOfferService.defaultTTL,
            now: Date = Date(),
        ) {
            self.userId = userId
            self.advertisedHost = advertisedHost
            self.advertisedHosts = advertisedHosts
            self.port = port
            self.ttl = ttl
            self.now = now
        }
    }

    public static func issue(_ input: IssueInput, db: DatabasePool) async throws -> LoginOfferIssue {
        let host = try advertisedHost(from: input)
        guard (1 ... 65_535).contains(input.port) else {
            throw BarkVisorError.badRequest("Invalid port")
        }
        let code = PairingCode.generate()
        let expires = input.now.addingTimeInterval(input.ttl)
        let record = LoginOfferRecord(
            id: UUID().uuidString,
            userId: input.userId,
            codeHash: PairingCode.hash(code),
            codeDisplay: code,
            host: host,
            port: input.port,
            createdAt: iso8601.string(from: input.now),
            expiresAt: iso8601.string(from: expires),
        )
        try await db.write { db in
            try LoginOfferRecord.deleteAll(db)
            try record.insert(db)
        }
        return issueResponse(record: record, ttl: input.ttl)
    }

    public static func current(
        now: Date = Date(),
        db: DatabasePool,
    ) async throws -> LoginOfferIssue {
        guard let record = try await db.read({ db in try LoginOfferRecord.fetchOne(db) }) else {
            throw BarkVisorError.notFound("No sign-in QR")
        }
        if record.consumedAt != nil {
            throw BarkVisorError.notFound("No sign-in QR")
        }
        if let expires = iso8601.date(from: record.expiresAt), now >= expires {
            throw BarkVisorError.notFound("No sign-in QR")
        }
        return issueResponse(record: record, ttl: remainingTTL(record, now: now))
    }

    public static func revoke(db: DatabasePool) async throws {
        try await db.write { db in
            try LoginOfferRecord.deleteAll(db)
        }
    }

    public static func redeem(
        code: String,
        keys: JWTKeyCollection,
        db: DatabasePool,
        now: Date = Date(),
    ) async throws -> AuthSessionTokens {
        guard PairingCode.isValid(code) else {
            throw BarkVisorError.unauthorized("Invalid sign-in code")
        }
        let incoming = PairingCode.hash(code)
        let user = try await db.write { db -> User in
            guard let offer = try LoginOfferRecord.fetchOne(db) else {
                throw BarkVisorError.unauthorized("Invalid sign-in code")
            }
            if offer.consumedAt != nil {
                throw BarkVisorError.unauthorized("Invalid sign-in code")
            }
            if let expires = iso8601.date(from: offer.expiresAt), now >= expires {
                throw BarkVisorError.unauthorized("Invalid sign-in code")
            }
            guard PairingCode.hashesEqual(incoming, offer.codeHash) else {
                throw BarkVisorError.unauthorized("Invalid sign-in code")
            }
            guard let user = try User.filter(User.Columns.id == offer.userId).fetchOne(db) else {
                throw BarkVisorError.unauthorized("Invalid sign-in code")
            }
            var consumed = offer
            consumed.consumedAt = iso8601.string(from: now)
            try consumed.update(db)
            return user
        }
        let token = try await AuthService.signAccessToken(user: user, keys: keys, now: now)
        let refresh = try await AuthService.issueRefreshToken(userId: user.id, db: db, now: now)
        return AuthSessionTokens(token: token, refreshToken: refresh, user: user)
    }

    private static func issueResponse(
        record: LoginOfferRecord,
        ttl: TimeInterval,
    ) -> LoginOfferIssue {
        let payload = LoginPayload(code: record.codeDisplay, host: record.host, port: record.port)
        return LoginOfferIssue(
            code: record.codeDisplay,
            expiresAt: record.expiresAt,
            ttlSeconds: Int(ttl.rounded(.up)),
            uri: payload.uri,
            host: record.host,
            port: record.port,
        )
    }

    private static func remainingTTL(_ record: LoginOfferRecord, now: Date) -> TimeInterval {
        guard let expires = iso8601.date(from: record.expiresAt) else { return 0 }
        return max(0, expires.timeIntervalSince(now))
    }

    private static func advertisedHost(from input: IssueInput) throws -> String {
        var candidates: [String] = []
        if let host = input.advertisedHost {
            candidates.append(host)
        }
        candidates.append(contentsOf: input.advertisedHosts)
        if let host = candidates.compactMap(PairingPayload.sanitizeHost).first {
            return host
        }
        throw BarkVisorError.badRequest(
            "No advertisable host; set advertisedHost or connect to a network",
        )
    }
}
