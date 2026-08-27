import Foundation
import GRDB
import JWTKit
import WebAuthn

public struct PasskeyRelyingParty: Sendable, Equatable {
    public let rpId: String
    public let origin: String

    public init(rpId: String, origin: String) {
        self.rpId = rpId
        self.origin = origin
    }
}

public struct PasskeyCeremonyBegin: Sendable {
    public let sessionId: String
    public let publicKeyJSON: Data

    public init(sessionId: String, publicKeyJSON: Data) {
        self.sessionId = sessionId
        self.publicKeyJSON = publicKeyJSON
    }

    public func responseBody() throws -> Data {
        let publicKey = try JSONSerialization.jsonObject(with: publicKeyJSON)
        return try JSONSerialization.data(
            withJSONObject: ["sessionId": sessionId, "publicKey": publicKey],
        )
    }
}

public enum PasskeyService {
    public static let relyingPartyName = "BarkVisor"
    public static let challengeTTL: TimeInterval = 5 * 60
    public static let hostnameNeededMessage =
        "Passkeys need a hostname (localhost, MagicDNS, or a DNS name), not a raw IP."

    public static func relyingParty(hostHeader: String?, originHeader: String?) throws -> PasskeyRelyingParty {
        let rpId = try rpId(fromHostHeader: hostHeader)
        guard let originHeader else {
            throw BarkVisorError.badRequest("Missing Origin")
        }
        let origin = originHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !origin.isEmpty, let url = URL(string: origin), let originHost = url.host, url.scheme != nil else {
            throw BarkVisorError.badRequest("Invalid Origin")
        }
        guard originHost.lowercased() == rpId else {
            throw BarkVisorError.badRequest("Origin does not match host")
        }
        return PasskeyRelyingParty(rpId: rpId, origin: origin)
    }

    public static func rpId(fromHostHeader hostHeader: String?) throws -> String {
        guard let hostHeader else {
            throw BarkVisorError.badRequest(hostnameNeededMessage)
        }
        let trimmed = hostHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest(hostnameNeededMessage)
        }
        if trimmed.hasPrefix("[") {
            throw BarkVisorError.badRequest(hostnameNeededMessage)
        }
        let hostname: String
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count != 2 || trimmed.count(where: { $0 == ":" }) != 1 {
                throw BarkVisorError.badRequest(hostnameNeededMessage)
            }
            hostname = String(parts[0])
        } else {
            hostname = trimmed
        }
        if isIPAddress(hostname) {
            throw BarkVisorError.badRequest(hostnameNeededMessage)
        }
        return hostname.lowercased()
    }

    public static func list(
        userId: String,
        db: DatabasePool,
    ) async throws -> [PasskeyCredentialResponse] {
        let rows = try await records(userId: userId, db: db)
        return rows.map(\.asResponse)
    }

    public static func beginRegister(
        user: User,
        name: String?,
        rp: PasskeyRelyingParty,
        db: DatabasePool,
        challenges: PasskeyChallengeStore = .shared,
        now: Date = Date(),
    ) async throws -> PasskeyCeremonyBegin {
        let existing = try await records(userId: user.id, db: db)
        let manager = manager(rp: rp)
        let options = manager.beginRegistration(
            user: PublicKeyCredentialUserEntity(
                id: Array(user.id.utf8),
                name: user.username,
                displayName: user.username,
            ),
            timeout: .seconds(5 * 60),
            attestation: .none,
            publicKeyCredentialParameters: [PublicKeyCredentialParameters(alg: .algES256)],
        )
        let sessionId = await challenges.store(
            kind: .register,
            challenge: options.challenge,
            rpId: rp.rpId,
            origin: rp.origin,
            userId: user.id,
            name: cleanedName(name),
            ttl: challengeTTL,
            now: now,
        )
        return try PasskeyCeremonyBegin(
            sessionId: sessionId,
            publicKeyJSON: encodeCreationOptions(
                options, excludeCredentialIds: existing.map(\.credentialId),
            ),
        )
    }

    public static func finishRegister(
        sessionId: String,
        credentialJSON: Data,
        name: String?,
        userId: String,
        rp: PasskeyRelyingParty,
        db: DatabasePool,
        challenges: PasskeyChallengeStore = .shared,
        now: Date = Date(),
    ) async throws -> PasskeyCredentialResponse {
        guard let session = await challenges.consume(sessionId, now: now) else {
            throw BarkVisorError.badRequest("Invalid or expired passkey session")
        }
        guard session.kind == .register, session.userId == userId else {
            throw BarkVisorError.unauthorized("Passkey registration failed")
        }
        guard session.rpId == rp.rpId, session.origin == rp.origin else {
            throw BarkVisorError.unauthorized("Passkey registration failed")
        }
        let credential: RegistrationCredential
        do {
            credential = try JSONDecoder().decode(RegistrationCredential.self, from: credentialJSON)
        } catch {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        let verified: Credential
        do {
            verified = try await manager(rp: rp).finishRegistration(
                challenge: session.challenge,
                credentialCreationData: credential,
                requireUserVerification: false,
                supportedPublicKeyAlgorithms: [PublicKeyCredentialParameters(alg: .algES256)],
                confirmCredentialIDNotRegisteredYet: { id in
                    let encoded = base64url(bytes: credential.rawID)
                    let exists = try await db.read { db in
                        try PasskeyCredential
                            .filter(PasskeyCredential.Columns.credentialId == encoded)
                            .fetchOne(db) != nil
                            || PasskeyCredential
                            .filter(PasskeyCredential.Columns.credentialId == id)
                            .fetchOne(db) != nil
                    }
                    return !exists
                },
            )
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.unauthorized("Passkey registration failed")
        }
        let credentialId = base64url(bytes: credential.rawID)
        let storedName = cleanedName(name) ?? session.name ?? "Passkey"
        let row = PasskeyCredential(
            id: UUID().uuidString,
            userId: userId,
            credentialId: credentialId,
            publicKey: Data(verified.publicKey),
            signCount: Int(verified.signCount),
            name: storedName,
            createdAt: iso8601.string(from: now),
            lastUsedAt: nil,
            transports: transportsJSON(from: credentialJSON),
        )
        do {
            try await db.write { db in
                try row.insert(db)
            }
        } catch {
            throw BarkVisorError.conflict("Passkey already registered")
        }
        return row.asResponse
    }

    public static func beginLogin(
        username: String?,
        rp: PasskeyRelyingParty,
        db: DatabasePool,
        challenges: PasskeyChallengeStore = .shared,
        now: Date = Date(),
    ) async throws -> PasskeyCeremonyBegin {
        var allow: [PublicKeyCredentialDescriptor]?
        if let username {
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let user = try await db.read({ db in
                    try User.filter(User.Columns.username == trimmed).fetchOne(db)
                }) {
                    let rows = try await records(userId: user.id, db: db)
                    allow = rows.compactMap { row in
                        guard let bytes = URLEncodedBase64(row.credentialId).decodedBytes else { return nil }
                        return PublicKeyCredentialDescriptor(id: bytes)
                    }
                }
            }
        }
        let options = manager(rp: rp).beginAuthentication(
            timeout: .seconds(5 * 60),
            allowCredentials: allow,
            userVerification: .preferred,
        )
        let sessionId = await challenges.store(
            kind: .login,
            challenge: options.challenge,
            rpId: rp.rpId,
            origin: rp.origin,
            userId: nil,
            name: nil,
            ttl: challengeTTL,
            now: now,
        )
        return try PasskeyCeremonyBegin(
            sessionId: sessionId,
            publicKeyJSON: JSONEncoder().encode(options),
        )
    }

    public static func finishLogin(
        sessionId: String,
        credentialJSON: Data,
        rp: PasskeyRelyingParty,
        keys: JWTKeyCollection,
        db: DatabasePool,
        challenges: PasskeyChallengeStore = .shared,
        now: Date = Date(),
    ) async throws -> AuthSessionTokens {
        guard let session = await challenges.consume(sessionId, now: now) else {
            throw BarkVisorError.badRequest("Invalid or expired passkey session")
        }
        guard session.kind == .login else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }
        guard session.rpId == rp.rpId, session.origin == rp.origin else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }
        let assertion: AuthenticationCredential
        do {
            assertion = try JSONDecoder().decode(AuthenticationCredential.self, from: credentialJSON)
        } catch {
            throw BarkVisorError.badRequest("Invalid passkey credential")
        }
        let credentialId = base64url(bytes: assertion.rawID)
        guard let row = try await db.read({ db in
            try PasskeyCredential.filter(PasskeyCredential.Columns.credentialId == credentialId).fetchOne(db)
        }) else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }
        do {
            let verified = try manager(rp: rp).finishAuthentication(
                credential: assertion,
                expectedChallenge: session.challenge,
                credentialPublicKey: [UInt8](row.publicKey),
                credentialCurrentSignCount: UInt32(row.signCount),
                requireUserVerification: false,
            )
            try await db.write { db in
                var updated = row
                updated.signCount = Int(verified.newSignCount)
                updated.lastUsedAt = iso8601.string(from: now)
                try updated.update(db)
            }
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }
        guard let user = try await db.read({ db in
            try User.fetchOne(db, key: row.userId)
        }) else {
            throw BarkVisorError.unauthorized("Invalid credentials")
        }
        let token = try await AuthService.signAccessToken(user: user, keys: keys, now: now)
        let refresh = try await AuthService.issueRefreshToken(userId: user.id, db: db, now: now)
        return AuthSessionTokens(token: token, refreshToken: refresh, user: user)
    }

    public static func delete(
        id: String,
        userId: String,
        db: DatabasePool,
    ) async throws {
        let deleted = try await db.write { db in
            try PasskeyCredential
                .filter(PasskeyCredential.Columns.id == id)
                .filter(PasskeyCredential.Columns.userId == userId)
                .deleteAll(db)
        }
        guard deleted > 0 else {
            throw BarkVisorError.notFound("Passkey not found")
        }
    }

    public static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard let n = Int(part, radix: 10), (0 ... 255).contains(n) else { return false }
        }
        return true
    }

    public static func base64url(bytes: [UInt8]) -> String {
        bytes.base64URLEncodedString().asString()
    }

    private static func manager(rp: PasskeyRelyingParty) -> WebAuthnManager {
        WebAuthnManager(
            configuration: .init(
                relyingPartyID: rp.rpId,
                relyingPartyName: relyingPartyName,
                relyingPartyOrigin: rp.origin,
            ),
        )
    }

    private static func records(userId: String, db: DatabasePool) async throws -> [PasskeyCredential] {
        try await db.read { db in
            try PasskeyCredential
                .filter(PasskeyCredential.Columns.userId == userId)
                .order(PasskeyCredential.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    private static func cleanedName(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func encodeCreationOptions(
        _ options: PublicKeyCredentialCreationOptions,
        excludeCredentialIds: [String],
    ) throws -> Data {
        let data = try JSONEncoder().encode(options)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BarkVisorError.internalError("Failed to encode passkey options")
        }
        obj["authenticatorSelection"] = [
            "residentKey": "required",
            "requireResidentKey": true,
            "userVerification": "preferred",
        ]
        if !excludeCredentialIds.isEmpty {
            obj["excludeCredentials"] = excludeCredentialIds.map {
                ["type": "public-key", "id": $0]
            }
        }
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private static func transportsJSON(from credentialJSON: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: credentialJSON) as? [String: Any],
              let response = obj["response"] as? [String: Any],
              let transports = response["transports"] as? [String],
              let data = try? JSONEncoder().encode(transports),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }
}
