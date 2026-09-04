import Foundation

/// Issued pairing offer shown as a short code / QR (PAS-45).
public struct PairingIssueResponse: Codable, Sendable, Equatable {
    public var code: String
    public var expiresAt: String
    public var ttlSeconds: Int
    public var qrPayload: String
    public var hostId: String
    public var fingerprint: String
    public var caFingerprint: String
    public var port: Int
    public var agentPort: Int
    public var advertisedHost: String?
    public var advertisedHosts: [String]
    public var apiVersion: Int

    public init(
        code: String,
        expiresAt: String,
        ttlSeconds: Int,
        qrPayload: String,
        hostId: String,
        fingerprint: String,
        caFingerprint: String,
        port: Int,
        agentPort: Int,
        advertisedHost: String? = nil,
        advertisedHosts: [String],
        apiVersion: Int = APIContract.version,
    ) {
        self.code = code
        self.expiresAt = expiresAt
        self.ttlSeconds = ttlSeconds
        self.qrPayload = qrPayload
        self.hostId = hostId
        self.fingerprint = fingerprint
        self.caFingerprint = caFingerprint
        self.port = port
        self.agentPort = agentPort
        self.advertisedHost = advertisedHost
        self.advertisedHosts = advertisedHosts
        self.apiVersion = apiVersion
    }
}

/// Redeem request sent by the joining Device to the issuer.
public struct PairingRedeemRequest: Codable, Sendable, Equatable {
    public var code: String
    public var hostId: String
    public var csrPEM: String
    public var deviceCertificatePEM: String
    public var caCertificatePEM: String
    public var apiVersion: Int?
    /// Joiner's advertised agent-plane address so the issuer can proxy back.
    public var agentHost: String?
    public var agentPort: Int?

    public init(
        code: String,
        hostId: String,
        csrPEM: String,
        deviceCertificatePEM: String,
        caCertificatePEM: String,
        apiVersion: Int? = APIContract.version,
        agentHost: String? = nil,
        agentPort: Int? = nil,
    ) {
        self.code = code
        self.hostId = hostId
        self.csrPEM = csrPEM
        self.deviceCertificatePEM = deviceCertificatePEM
        self.caCertificatePEM = caCertificatePEM
        self.apiVersion = apiVersion
        self.agentHost = agentHost
        self.agentPort = agentPort
    }
}

/// Admin row copied at pair time (PAS-81). Password is the stored hash only.
public struct PairingAdminUser: Codable, Sendable, Equatable {
    public var id: String
    public var username: String
    public var passwordHash: String

    public init(id: String, username: String, passwordHash: String) {
        self.id = id
        self.username = username
        self.passwordHash = passwordHash
    }
}

/// Shared login material copied at pair time (PAS-81). Sealed to the joiner
/// Device key before it ever goes on the wire.
public struct PairingSharedIdentity: Codable, Sendable, Equatable {
    public var jwtSecret: String
    public var adminUser: PairingAdminUser?

    public init(jwtSecret: String, adminUser: PairingAdminUser?) {
        self.jwtSecret = jwtSecret
        self.adminUser = adminUser
    }
}

/// AES-GCM envelope holding `PairingSharedIdentity`, sealed under ECDH of the
/// issuer Device key and the joiner Device certificate public key so a LAN
/// observer of the plaintext HTTP redeem cannot read the HMAC secret or the
/// admin password hash.
public struct PairingIdentitySeal: Codable, Sendable, Equatable {
    public var ciphertext: String

    public init(ciphertext: String) {
        self.ciphertext = ciphertext
    }
}

/// Trust material returned by a successful redeem.
public struct PairingRedeemResponse: Codable, Sendable, Equatable {
    public var hostId: String
    public var deviceCertificatePEM: String
    public var deviceFingerprint: String
    public var caCertificatePEM: String
    public var caFingerprint: String
    public var issuedCertificatePEM: String
    public var issuedFingerprint: String
    public var agentPort: Int
    public var apiVersion: Int
    public var identitySeal: PairingIdentitySeal?
    public var jwtSecret: String?
    public var adminUser: PairingAdminUser?

    public init(
        hostId: String,
        deviceCertificatePEM: String,
        deviceFingerprint: String,
        caCertificatePEM: String,
        caFingerprint: String,
        issuedCertificatePEM: String,
        issuedFingerprint: String,
        agentPort: Int,
        apiVersion: Int = APIContract.version,
        identitySeal: PairingIdentitySeal? = nil,
        jwtSecret: String? = nil,
        adminUser: PairingAdminUser? = nil,
    ) {
        self.hostId = hostId
        self.deviceCertificatePEM = deviceCertificatePEM
        self.deviceFingerprint = deviceFingerprint
        self.caCertificatePEM = caCertificatePEM
        self.caFingerprint = caFingerprint
        self.issuedCertificatePEM = issuedCertificatePEM
        self.issuedFingerprint = issuedFingerprint
        self.agentPort = agentPort
        self.apiVersion = apiVersion
        self.identitySeal = identitySeal
        self.jwtSecret = jwtSecret
        self.adminUser = adminUser
    }
}

/// Local join request: QR URI and/or structured fields.
public struct PairingJoinRequest: Codable, Sendable, Equatable {
    public var qrPayload: String?
    public var code: String?
    public var host: String?
    public var port: Int?
    public var hostId: String?
    public var fingerprint: String?

    public init(
        qrPayload: String? = nil,
        code: String? = nil,
        host: String? = nil,
        port: Int? = nil,
        hostId: String? = nil,
        fingerprint: String? = nil,
    ) {
        self.qrPayload = qrPayload
        self.code = code
        self.host = host
        self.port = port
        self.hostId = hostId
        self.fingerprint = fingerprint
    }
}

/// Local result after pinning the issuer.
public struct PairingJoinResponse: Codable, Sendable, Equatable {
    public var peerHostId: String
    public var peerFingerprint: String
    public var issuedFingerprint: String
    public var agentPort: Int
    public var pinned: Bool
    public var apiVersion: Int

    public init(
        peerHostId: String,
        peerFingerprint: String,
        issuedFingerprint: String,
        agentPort: Int = Config.agentPort,
        pinned: Bool = true,
        apiVersion: Int = APIContract.version,
    ) {
        self.peerHostId = peerHostId
        self.peerFingerprint = peerFingerprint
        self.issuedFingerprint = issuedFingerprint
        self.agentPort = agentPort
        self.pinned = pinned
        self.apiVersion = apiVersion
    }
}

/// Persisted last-pair trust bundle. Does not replace local Home CA / SQLite.
public struct PairingPeerReceipt: Codable, Sendable, Equatable {
    public var peerHostId: String
    public var peerFingerprint: String
    public var caCertificatePEM: String
    public var caFingerprint: String
    public var issuedCertificatePEM: String
    public var issuedFingerprint: String
    public var agentPort: Int
    public var pairedAt: String

    public init(
        peerHostId: String,
        peerFingerprint: String,
        caCertificatePEM: String,
        caFingerprint: String,
        issuedCertificatePEM: String,
        issuedFingerprint: String,
        agentPort: Int = Config.agentPort,
        pairedAt: String,
    ) {
        self.peerHostId = peerHostId
        self.peerFingerprint = peerFingerprint
        self.caCertificatePEM = caCertificatePEM
        self.caFingerprint = caFingerprint
        self.issuedCertificatePEM = issuedCertificatePEM
        self.issuedFingerprint = issuedFingerprint
        self.agentPort = agentPort
        self.pairedAt = pairedAt
    }

    enum CodingKeys: String, CodingKey {
        case peerHostId, peerFingerprint, caCertificatePEM, caFingerprint
        case issuedCertificatePEM, issuedFingerprint, agentPort, pairedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.peerHostId = try container.decode(String.self, forKey: .peerHostId)
        self.peerFingerprint = try container.decode(String.self, forKey: .peerFingerprint)
        self.caCertificatePEM = try container.decode(String.self, forKey: .caCertificatePEM)
        self.caFingerprint = try container.decode(String.self, forKey: .caFingerprint)
        self.issuedCertificatePEM = try container.decode(String.self, forKey: .issuedCertificatePEM)
        self.issuedFingerprint = try container.decode(String.self, forKey: .issuedFingerprint)
        self.agentPort = try container.decodeIfPresent(Int.self, forKey: .agentPort) ?? Config.agentPort
        self.pairedAt = try container.decode(String.self, forKey: .pairedAt)
    }
}
