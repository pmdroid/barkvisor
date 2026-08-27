#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import GRDB
import JWTKit
import Testing
@testable import BarkVisorCore

struct PasskeyServiceTests {
    private let origin = "http://localhost:7777"
    private let rp = PasskeyRelyingParty(rpId: "localhost", origin: "http://localhost:7777")

    private func makeDB() throws -> (URL, DatabasePool) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        try pool.write { db in
            try User(
                id: "user-1",
                username: "admin",
                password: "hashed:testpass10",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
            try User(
                id: "user-2",
                username: "other",
                password: "hashed:testpass10",
                createdAt: "2025-01-01T00:00:00Z",
            ).insert(db)
        }
        return (tmp, pool)
    }

    private func makeKeys() async -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "passkey-test-secret"), digestAlgorithm: .sha256)
        return keys
    }

    private func admin() -> User {
        User(
            id: "user-1",
            username: "admin",
            password: "hashed:testpass10",
            createdAt: "2025-01-01T00:00:00Z",
        )
    }

    @Test func `ip host is rejected`() throws {
        let error = #expect(throws: BarkVisorError.self) {
            try PasskeyService.rpId(fromHostHeader: "192.168.1.10:7777")
        }
        #expect(error?.httpStatus == 400)
        let v6 = #expect(throws: BarkVisorError.self) {
            try PasskeyService.rpId(fromHostHeader: "[::1]:7777")
        }
        #expect(v6?.httpStatus == 400)
        #expect(try PasskeyService.rpId(fromHostHeader: "localhost:7777") == "localhost")
        #expect(try PasskeyService.rpId(fromHostHeader: "home.tail1234.ts.net") == "home.tail1234.ts.net")
    }

    @Test func `origin must match host`() throws {
        let error = #expect(throws: BarkVisorError.self) {
            try PasskeyService.relyingParty(
                hostHeader: "localhost:7777",
                originHeader: "http://evil.example:7777",
            )
        }
        #expect(error?.httpStatus == 400)
        let rp = try PasskeyService.relyingParty(
            hostHeader: "localhost:7777",
            originHeader: origin,
        )
        #expect(rp.rpId == "localhost")
        #expect(rp.origin == origin)
        let port = #expect(throws: BarkVisorError.self) {
            try PasskeyService.relyingParty(
                hostHeader: "localhost:7777",
                originHeader: "http://localhost:8443",
            )
        }
        #expect(port?.httpStatus == 400)
    }

    @Test func `register and login roundtrip`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let challenges = PasskeyChallengeStore()
        let authenticator = PasskeyTestAuthenticator()

        let listed = try await PasskeyService.list(userId: "user-1", db: db)
        #expect(listed.isEmpty)

        let begin = try await PasskeyService.beginRegister(
            user: admin(), name: "Laptop", rp: rp, db: db, challenges: challenges,
        )
        let challenge = try Self.challengeString(begin)
        let createJSON = try authenticator.registrationJSON(
            challenge: challenge, rpId: rp.rpId, origin: origin, signCount: 0,
        )
        let stored = try await PasskeyService.finishRegister(
            sessionId: begin.sessionId,
            credentialJSON: createJSON,
            name: "Laptop",
            userId: "user-1",
            rp: rp,
            db: db,
            challenges: challenges,
        )
        #expect(stored.name == "Laptop")
        #expect(stored.lastUsedAt == nil)

        let after = try await PasskeyService.list(userId: "user-1", db: db)
        #expect(after.count == 1)

        let loginBegin = try await PasskeyService.beginLogin(
            rp: rp, challenges: challenges,
        )
        let getJSON = try authenticator.assertionJSON(
            challenge: Self.challengeString(loginBegin),
            rpId: rp.rpId,
            origin: origin,
            signCount: 0,
        )
        let session = try await PasskeyService.finishLogin(
            sessionId: loginBegin.sessionId,
            credentialJSON: getJSON,
            rp: rp,
            keys: keys,
            db: db,
            challenges: challenges,
        )
        #expect(session.user.id == "user-1")
        #expect(session.token.isEmpty == false)
        let payload = try await keys.verify(session.token, as: UserPayload.self)
        #expect(payload.username == "admin")
    }

    @Test func `replayed challenge is rejected`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let challenges = PasskeyChallengeStore()
        let authenticator = PasskeyTestAuthenticator()
        let begin = try await PasskeyService.beginRegister(
            user: admin(), name: nil, rp: rp, db: db, challenges: challenges,
        )
        let json = try authenticator.registrationJSON(
            challenge: Self.challengeString(begin), rpId: rp.rpId, origin: origin, signCount: 0,
        )
        _ = try await PasskeyService.finishRegister(
            sessionId: begin.sessionId, credentialJSON: json, name: nil, userId: "user-1", rp: rp,
            db: db, challenges: challenges,
        )
        let replay = await #expect(throws: BarkVisorError.self) {
            try await PasskeyService.finishRegister(
                sessionId: begin.sessionId, credentialJSON: json, name: nil, userId: "user-1", rp: rp,
                db: db, challenges: challenges,
            )
        }
        #expect(replay?.httpStatus == 400)
    }

    @Test func `bad origin is rejected`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let challenges = PasskeyChallengeStore()
        let authenticator = PasskeyTestAuthenticator()
        let begin = try await PasskeyService.beginRegister(
            user: admin(), name: nil, rp: rp, db: db, challenges: challenges,
        )
        let other = PasskeyRelyingParty(rpId: "localhost", origin: "http://localhost:9")
        let json = try authenticator.registrationJSON(
            challenge: Self.challengeString(begin), rpId: rp.rpId, origin: origin, signCount: 0,
        )
        let error = await #expect(throws: BarkVisorError.self) {
            try await PasskeyService.finishRegister(
                sessionId: begin.sessionId, credentialJSON: json, name: nil, userId: "user-1", rp: other,
                db: db, challenges: challenges,
            )
        }
        #expect(error?.httpStatus == 401)
    }

    @Test func `wrong user cannot finish registration`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let challenges = PasskeyChallengeStore()
        let authenticator = PasskeyTestAuthenticator()
        let begin = try await PasskeyService.beginRegister(
            user: admin(), name: nil, rp: rp, db: db, challenges: challenges,
        )
        let json = try authenticator.registrationJSON(
            challenge: Self.challengeString(begin), rpId: rp.rpId, origin: origin, signCount: 0,
        )
        let error = await #expect(throws: BarkVisorError.self) {
            try await PasskeyService.finishRegister(
                sessionId: begin.sessionId, credentialJSON: json, name: nil, userId: "user-2", rp: rp,
                db: db, challenges: challenges,
            )
        }
        #expect(error?.httpStatus == 401)
    }

    @Test func `signCount zero stays zero and non-zero must not decrease`() async throws {
        let (tmp, db) = try makeDB()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let keys = await makeKeys()
        let challenges = PasskeyChallengeStore()
        let authenticator = PasskeyTestAuthenticator()
        let begin = try await PasskeyService.beginRegister(
            user: admin(), name: nil, rp: rp, db: db, challenges: challenges,
        )
        _ = try await PasskeyService.finishRegister(
            sessionId: begin.sessionId,
            credentialJSON: authenticator.registrationJSON(
                challenge: Self.challengeString(begin), rpId: rp.rpId, origin: origin, signCount: 0,
            ),
            name: nil,
            userId: "user-1",
            rp: rp,
            db: db,
            challenges: challenges,
        )

        let zeroBegin = try await PasskeyService.beginLogin(
            rp: rp, challenges: challenges,
        )
        _ = try await PasskeyService.finishLogin(
            sessionId: zeroBegin.sessionId,
            credentialJSON: authenticator.assertionJSON(
                challenge: Self.challengeString(zeroBegin),
                rpId: rp.rpId,
                origin: origin,
                signCount: 0,
            ),
            rp: rp,
            keys: keys,
            db: db,
            challenges: challenges,
        )
        let storedZero = try await db.read { db in
            try PasskeyCredential.fetchOne(db)
        }
        #expect(storedZero?.signCount == 0)

        let upBegin = try await PasskeyService.beginLogin(
            rp: rp, challenges: challenges,
        )
        _ = try await PasskeyService.finishLogin(
            sessionId: upBegin.sessionId,
            credentialJSON: authenticator.assertionJSON(
                challenge: Self.challengeString(upBegin),
                rpId: rp.rpId,
                origin: origin,
                signCount: 2,
            ),
            rp: rp,
            keys: keys,
            db: db,
            challenges: challenges,
        )
        let storedUp = try await db.read { db in
            try PasskeyCredential.fetchOne(db)
        }
        #expect(storedUp?.signCount == 2)

        let downBegin = try await PasskeyService.beginLogin(
            rp: rp, challenges: challenges,
        )
        let down = await #expect(throws: BarkVisorError.self) {
            try await PasskeyService.finishLogin(
                sessionId: downBegin.sessionId,
                credentialJSON: authenticator.assertionJSON(
                    challenge: Self.challengeString(downBegin),
                    rpId: rp.rpId,
                    origin: origin,
                    signCount: 1,
                ),
                rp: rp,
                keys: keys,
                db: db,
                challenges: challenges,
            )
        }
        #expect(down?.httpStatus == 401)
    }

    private static func challengeString(_ begin: PasskeyCeremonyBegin) throws -> String {
        let body = try begin.responseBody()
        let obj = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let publicKey = try #require(obj["publicKey"] as? [String: Any])
        return try #require(publicKey["challenge"] as? String)
    }
}

private struct PasskeyTestAuthenticator {
    let key = P256.Signing.PrivateKey()
    let credentialId: [UInt8] = Array(repeating: 0x11, count: 16)

    func registrationJSON(challenge: String, rpId: String, origin: String, signCount: UInt32) throws -> Data {
        let clientData = try clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin)
        let authData = authenticatorData(rpId: rpId, signCount: signCount, attested: true)
        let attestation = cborMap([
            (cborText("fmt"), cborText("none")),
            (cborText("attStmt"), [0xA0]),
            (cborText("authData"), cborBytes(authData)),
        ])
        let body: [String: Any] = [
            "id": PasskeyService.base64url(bytes: credentialId),
            "rawId": PasskeyService.base64url(bytes: credentialId),
            "type": "public-key",
            "response": [
                "clientDataJSON": PasskeyService.base64url(bytes: [UInt8](clientData)),
                "attestationObject": PasskeyService.base64url(bytes: attestation),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    func assertionJSON(challenge: String, rpId: String, origin: String, signCount: UInt32) throws -> Data {
        let clientData = try clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin)
        let authData = authenticatorData(rpId: rpId, signCount: signCount, attested: false)
        let clientHash = SHA256.hash(data: clientData)
        let signatureBase = Data(authData) + Data(clientHash)
        let signature = try key.signature(for: signatureBase)
        let body: [String: Any] = [
            "id": PasskeyService.base64url(bytes: credentialId),
            "rawId": PasskeyService.base64url(bytes: credentialId),
            "type": "public-key",
            "response": [
                "clientDataJSON": PasskeyService.base64url(bytes: [UInt8](clientData)),
                "authenticatorData": PasskeyService.base64url(bytes: authData),
                "signature": PasskeyService.base64url(bytes: [UInt8](signature.derRepresentation)),
                "userHandle": PasskeyService.base64url(bytes: Array("user-1".utf8)),
            ],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func clientDataJSON(type: String, challenge: String, origin: String) throws -> Data {
        let obj: [String: Any] = ["type": type, "challenge": challenge, "origin": origin]
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func authenticatorData(rpId: String, signCount: UInt32, attested: Bool) -> [UInt8] {
        var bytes = [UInt8](SHA256.hash(data: Data(rpId.utf8)))
        bytes.append(attested ? 0x45 : 0x05)
        bytes.append(contentsOf: [
            UInt8(truncatingIfNeeded: signCount >> 24),
            UInt8(truncatingIfNeeded: signCount >> 16),
            UInt8(truncatingIfNeeded: signCount >> 8),
            UInt8(truncatingIfNeeded: signCount),
        ])
        if attested {
            bytes.append(contentsOf: Array(repeating: 0, count: 16))
            let idLen = UInt16(credentialId.count)
            bytes.append(UInt8(idLen >> 8))
            bytes.append(UInt8(idLen & 0xFF))
            bytes.append(contentsOf: credentialId)
            bytes.append(contentsOf: cosePublicKey())
        }
        return bytes
    }

    private func cosePublicKey() -> [UInt8] {
        let x9 = [UInt8](key.publicKey.x963Representation)
        let x = Array(x9[1 ..< 33])
        let y = Array(x9[33 ..< 65])
        return cborMap([
            (cborUnsigned(1), cborUnsigned(2)),
            (cborUnsigned(3), cborNegative(-7)),
            (cborNegative(-1), cborUnsigned(1)),
            (cborNegative(-2), cborBytes(x)),
            (cborNegative(-3), cborBytes(y)),
        ])
    }
}

private func cborHeader(major: UInt8, count: Int) -> [UInt8] {
    let hi = major << 5
    if count < 24 { return [hi | UInt8(count)] }
    if count <= 255 { return [hi | 24, UInt8(count)] }
    return [hi | 25, UInt8(count >> 8), UInt8(count & 0xFF)]
}

private func cborUnsigned(_ n: UInt64) -> [UInt8] {
    cborHeader(major: 0, count: Int(n))
}

private func cborNegative(_ n: Int) -> [UInt8] {
    let additional = -1 - n
    return cborHeader(major: 1, count: additional)
}

private func cborBytes(_ bytes: [UInt8]) -> [UInt8] {
    cborHeader(major: 2, count: bytes.count) + bytes
}

private func cborText(_ text: String) -> [UInt8] {
    let bytes = Array(text.utf8)
    return cborHeader(major: 3, count: bytes.count) + bytes
}

private func cborMap(_ pairs: [([UInt8], [UInt8])]) -> [UInt8] {
    cborHeader(major: 5, count: pairs.count) + pairs.flatMap { $0.0 + $0.1 }
}
