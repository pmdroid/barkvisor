import Crypto
import Foundation
import JWTKit
import X509

public struct HomeScopedCredential: Equatable, Sendable {
    public static let prefix = "bvsc1."

    public var issuerHostId: String
    public var subject: String
    public var username: String
    public var role: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var membershipRevision: Int

    public init(
        issuerHostId: String,
        subject: String,
        username: String,
        role: String,
        issuedAt: Date,
        expiresAt: Date,
        membershipRevision: Int,
    ) {
        self.issuerHostId = issuerHostId
        self.subject = subject
        self.username = username
        self.role = role
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.membershipRevision = membershipRevision
    }
}

public struct HomeManagementCredential: Equatable, Sendable {
    public static let prefix = "bvmc1."

    public var issuerHostId: String
    public var subject: String
    public var username: String
    public var role: String
    public var onBehalfOfHostId: String
    public var issuedAt: Date
    public var expiresAt: Date
    public var membershipRevision: Int

    public init(
        issuerHostId: String,
        subject: String,
        username: String,
        role: String,
        onBehalfOfHostId: String,
        issuedAt: Date,
        expiresAt: Date,
        membershipRevision: Int,
    ) {
        self.issuerHostId = issuerHostId
        self.subject = subject
        self.username = username
        self.role = role
        self.onBehalfOfHostId = onBehalfOfHostId
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.membershipRevision = membershipRevision
    }
}

public enum HomeMemberHop {
    public static func token(
        dataDir: URL,
        issuerHostId: String,
        userId: String,
        username: String,
        role: String,
        keys: JWTKeyCollection,
        now: Date = Date(),
        ttl: TimeInterval = AuthService.memberHopTokenTTL,
    ) async throws -> String {
        let keyURL = HomeCAService.agentDirectory(in: dataDir)
            .appendingPathComponent(HomeCAService.deviceKeyFileName)
        if let pem = try? String(contentsOf: keyURL, encoding: .utf8), pem.contains("PRIVATE") {
            let revision = (try? HomeMembershipAuthority(dataDir: dataDir).currentRevision()) ?? 0
            return try HomeScopedCredential.sign(
                issuerHostId: issuerHostId,
                subject: userId,
                username: username,
                role: role,
                membershipRevision: revision,
                deviceKeyPEM: pem,
                now: now,
                ttl: ttl,
            )
        }
        return try await AuthService.signMemberHopToken(
            userId: userId,
            username: username,
            role: role,
            keys: keys,
            now: now,
            ttl: ttl,
        )
    }

    public static func localManagementToken(
        dataDir: URL,
        localHostId: String,
        peerHostId: String,
        peerCertificatePEM: String,
        scopedToken: String,
        now: Date = Date(),
    ) throws -> String {
        let scoped = try HomeScopedCredential.verify(
            token: scopedToken,
            issuerCertificatePEM: peerCertificatePEM,
            now: now,
        )
        guard scoped.issuerHostId.caseInsensitiveCompare(peerHostId) == .orderedSame else {
            throw BarkVisorError.unauthorized("Hop credential is not bound to the presented Device")
        }
        let authority = HomeMembershipAuthority(dataDir: dataDir)
        let decision = authority.authorizeLoginToken(
            issuerHostId: scoped.issuerHostId,
            subjectHostId: nil,
            issuedAt: scoped.issuedAt,
            expiresAt: scoped.expiresAt,
            membershipRevision: scoped.membershipRevision,
            localHostId: localHostId,
            now: now,
        )
        guard case .allow = decision else {
            throw BarkVisorError.unauthorized("Home membership denied this login token")
        }
        let managementKey = try authority.managementKeyPEM()
        return try HomeManagementCredential.sign(
            issuerHostId: localHostId,
            subject: scoped.subject,
            username: scoped.username,
            role: scoped.role,
            onBehalfOfHostId: peerHostId,
            membershipRevision: scoped.membershipRevision,
            managementKeyPEM: managementKey,
            now: now,
        )
    }
}

extension HomeScopedCredential {
    public static func sign(
        issuerHostId: String,
        subject: String,
        username: String,
        role: String,
        membershipRevision: Int,
        deviceKeyPEM: String,
        now: Date = Date(),
        ttl: TimeInterval = AuthService.memberHopTokenTTL,
    ) throws -> String {
        let bounded = min(ttl, HomeMembershipPolicy.maximumStaleAuthorizationWindow)
        let payload = ScopedBody(
            iss: issuerHostId,
            sub: subject,
            username: username,
            role: role,
            iat: Int(now.timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(bounded).timeIntervalSince1970),
            rev: membershipRevision,
        )
        return try HomeCredentialCodec.sign(
            prefix: prefix,
            payload: payload,
            privateKeyPEM: deviceKeyPEM,
        )
    }

    public static func verify(
        token: String,
        issuerCertificatePEM: String,
        now: Date = Date(),
    ) throws -> HomeScopedCredential {
        let body: ScopedBody = try HomeCredentialCodec.verify(
            prefix: prefix,
            token: token,
            signerPEM: issuerCertificatePEM,
        )
        try HomeCredentialCodec.requireLifetime(
            issuedAt: body.iat,
            expiresAt: body.exp,
            now: now,
        )
        return HomeScopedCredential(
            issuerHostId: body.iss,
            subject: body.sub,
            username: body.username,
            role: body.role,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(body.iat)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(body.exp)),
            membershipRevision: body.rev,
        )
    }
}

extension HomeManagementCredential {
    public static func sign(
        issuerHostId: String,
        subject: String,
        username: String,
        role: String,
        onBehalfOfHostId: String,
        membershipRevision: Int,
        managementKeyPEM: String,
        now: Date = Date(),
        ttl: TimeInterval = AuthService.memberHopTokenTTL,
    ) throws -> String {
        let bounded = min(ttl, HomeMembershipPolicy.maximumStaleAuthorizationWindow)
        let payload = ManagementBody(
            iss: issuerHostId,
            sub: subject,
            username: username,
            role: role,
            obo: onBehalfOfHostId,
            iat: Int(now.timeIntervalSince1970),
            exp: Int(now.addingTimeInterval(bounded).timeIntervalSince1970),
            rev: membershipRevision,
        )
        return try HomeCredentialCodec.sign(
            prefix: prefix,
            payload: payload,
            privateKeyPEM: managementKeyPEM,
        )
    }

    public static func verify(
        token: String,
        managementPublicKeyPEM: String,
        now: Date = Date(),
    ) throws -> HomeManagementCredential {
        let body: ManagementBody = try HomeCredentialCodec.verify(
            prefix: prefix,
            token: token,
            signerPEM: managementPublicKeyPEM,
        )
        try HomeCredentialCodec.requireLifetime(
            issuedAt: body.iat,
            expiresAt: body.exp,
            now: now,
        )
        return HomeManagementCredential(
            issuerHostId: body.iss,
            subject: body.sub,
            username: body.username,
            role: body.role,
            onBehalfOfHostId: body.obo,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(body.iat)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(body.exp)),
            membershipRevision: body.rev,
        )
    }
}

private struct ScopedBody: Codable {
    var iss: String
    var sub: String
    var username: String
    var role: String
    var iat: Int
    var exp: Int
    var rev: Int
}

private struct ManagementBody: Codable {
    var iss: String
    var sub: String
    var username: String
    var role: String
    var obo: String
    var iat: Int
    var exp: Int
    var rev: Int
}

enum HomeCredentialCodec {
    static func sign(
        prefix: String,
        payload: some Encodable,
        privateKeyPEM: String,
    ) throws -> String {
        let data = try canonical(payload)
        let key = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let signature = try key.signature(for: data)
        return prefix
            + base64URL(data)
            + "."
            + base64URL(signature.derRepresentation)
    }

    static func verify<Payload: Decodable>(
        prefix: String,
        token: String,
        signerPEM: String,
    ) throws -> Payload {
        guard token.hasPrefix(prefix) else {
            throw BarkVisorError.unauthorized("Unrecognized credential")
        }
        let rest = token.dropFirst(prefix.count)
        let parts = rest.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw BarkVisorError.unauthorized("Unrecognized credential")
        }
        guard let data = base64URLDecode(String(parts[0])),
              let signatureData = base64URLDecode(String(parts[1]))
        else {
            throw BarkVisorError.unauthorized("Unrecognized credential")
        }
        let publicKey = try signingPublicKey(pem: signerPEM)
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        guard publicKey.isValidSignature(signature, for: data) else {
            throw BarkVisorError.unauthorized("Credential signature is invalid")
        }
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private static func signingPublicKey(pem: String) throws -> P256.Signing.PublicKey {
        if let key = try? P256.Signing.PublicKey(pemRepresentation: pem) {
            return key
        }
        let certificate = try Certificate(pemEncoded: pem)
        guard let key = P256.Signing.PublicKey(certificate.publicKey) else {
            throw BarkVisorError.unauthorized("Credential signer is not a Device key")
        }
        return key
    }

    static func requireLifetime(issuedAt: Int, expiresAt: Int, now: Date) throws {
        let issued = Date(timeIntervalSince1970: TimeInterval(issuedAt))
        let expires = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        if expires <= issued
            || expires.timeIntervalSince(issued) > HomeMembershipPolicy.maximumStaleAuthorizationWindow
            || now < issued.addingTimeInterval(-60)
            || now >= expires {
            throw BarkVisorError.unauthorized("Credential is outside its authorization window")
        }
    }

    private static func canonical(_ payload: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder != 0 {
            padded.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: padded)
    }
}
