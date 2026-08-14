import Foundation
import GRDB
import X509

/// Pairing issue + redeem (PAS-45) and shared login copy (PAS-81).
///
/// The existing Device issues a short-lived code / QR. The joining Device
/// redeems it and both sides record pairwise pins. Home CA issues a peer
/// cert as trust material on the wire. Redeem also attaches the issuer
/// jwt-secret and admin user hash so one login works on both Devices.
/// Local SQLite / QEMU stay authoritative (PAS-47 / PAS-90).
public enum PairingService {
    public static let defaultTTL: TimeInterval = 10 * 60
    public static let receiptFileName = "pairing-peer.json"
    public static let pendingRedeemFileName = "pairing-redeem-pending.json"

    /// Disk-only wrapper so a pending redeem cannot be reused for a later
    /// offer from the same host (new one-time code).
    struct PendingRedeemRecord: Codable, Equatable {
        var codeHash: String
        var response: PairingRedeemResponse
    }

    public struct IssueInput: Sendable {
        public var dataDir: URL
        public var hostId: String
        public var port: Int
        public var agentPort: Int
        public var advertisedHost: String?
        public var advertisedHosts: [String]
        public var ttl: TimeInterval
        public var now: Date

        public init(
            dataDir: URL,
            hostId: String,
            port: Int = Config.port,
            agentPort: Int = Config.agentPort,
            advertisedHost: String? = nil,
            advertisedHosts: [String] = PairingAddresses.advertisedIPv4(),
            ttl: TimeInterval = PairingService.defaultTTL,
            now: Date = Date(),
        ) {
            self.dataDir = dataDir
            self.hostId = hostId
            self.port = port
            self.agentPort = agentPort
            self.advertisedHost = advertisedHost
            self.advertisedHosts = advertisedHosts
            self.ttl = ttl
            self.now = now
        }
    }

    public static func issue(
        _ input: IssueInput,
        offers: PairingOfferStore? = nil,
    ) throws -> PairingIssueResponse {
        let host = try advertisedHost(from: input)
        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(dataDir: input.dataDir, hostId: input.hostId)
        } catch {
            throw PairingError.unavailable(
                "Home CA is unavailable; local runtime continues: \(error.localizedDescription)",
            )
        }

        let code = PairingCode.generate()
        let expires = input.now.addingTimeInterval(input.ttl)
        let offer = PairingOffer(
            codeHash: PairingCode.hash(code),
            codeDisplay: code,
            createdAt: iso8601.string(from: input.now),
            expiresAt: iso8601.string(from: expires),
            agentPort: input.agentPort,
        )
        let store = offers ?? PairingOfferStore(dataDir: input.dataDir)
        do {
            try store.replace(offer)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist pairing offer: \(error.localizedDescription)",
            )
        }

        let payload = PairingPayload(
            code: code,
            host: host,
            port: input.port,
            agentPort: input.agentPort,
            hostId: input.hostId,
            fingerprint: material.deviceFingerprint,
        )
        return PairingIssueResponse(
            code: code,
            expiresAt: offer.expiresAt,
            ttlSeconds: Int(input.ttl),
            qrPayload: payload.uri,
            hostId: input.hostId,
            fingerprint: material.deviceFingerprint,
            caFingerprint: material.caFingerprint,
            port: input.port,
            agentPort: input.agentPort,
            advertisedHosts: input.advertisedHosts,
        )
    }

    public static func currentOffer(
        _ input: IssueInput,
        offers: PairingOfferStore? = nil,
    ) throws -> PairingIssueResponse {
        let store = offers ?? PairingOfferStore(dataDir: input.dataDir)
        guard let offer = try store.load() else {
            throw PairingError.noActiveOffer
        }
        if offer.consumedAt != nil {
            throw PairingError.noActiveOffer
        }
        if let expires = iso8601.date(from: offer.expiresAt), input.now >= expires {
            throw PairingError.noActiveOffer
        }
        let host = try advertisedHost(from: input)
        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(dataDir: input.dataDir, hostId: input.hostId)
        } catch {
            throw PairingError.unavailable(
                "Home CA is unavailable; local runtime continues: \(error.localizedDescription)",
            )
        }
        let payload = PairingPayload(
            code: offer.codeDisplay,
            host: host,
            port: input.port,
            agentPort: offer.agentPort,
            hostId: input.hostId,
            fingerprint: material.deviceFingerprint,
        )
        let ttl: Int = if let expires = iso8601.date(from: offer.expiresAt) {
            max(0, Int(expires.timeIntervalSince(input.now)))
        } else {
            0
        }
        return PairingIssueResponse(
            code: offer.codeDisplay,
            expiresAt: offer.expiresAt,
            ttlSeconds: ttl,
            qrPayload: payload.uri,
            hostId: input.hostId,
            fingerprint: material.deviceFingerprint,
            caFingerprint: material.caFingerprint,
            port: input.port,
            agentPort: offer.agentPort,
            advertisedHosts: input.advertisedHosts,
        )
    }

    public static func revoke(dataDir: URL, offers: PairingOfferStore? = nil) throws {
        let store = offers ?? PairingOfferStore(dataDir: dataDir)
        do {
            try store.clear()
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to revoke pairing offer: \(error.localizedDescription)",
            )
        }
    }

    public struct RedeemInput: Sendable {
        public var dataDir: URL
        public var issuerHostId: String
        public var request: PairingRedeemRequest
        public var now: Date
        public var jwtSecret: String?
        public var adminUser: PairingAdminUser?

        public init(
            dataDir: URL,
            issuerHostId: String,
            request: PairingRedeemRequest,
            now: Date = Date(),
            jwtSecret: String? = nil,
            adminUser: PairingAdminUser? = nil,
        ) {
            self.dataDir = dataDir
            self.issuerHostId = issuerHostId
            self.request = request
            self.now = now
            self.jwtSecret = jwtSecret
            self.adminUser = adminUser
        }
    }

    public static func redeem(
        _ input: RedeemInput,
        offers: PairingOfferStore? = nil,
        pins: PeerPinStore? = nil,
    ) throws -> PairingRedeemResponse {
        let req = input.request
        guard req.apiVersion == APIContract.version else {
            throw PairingError.incompatibleAPIVersion(
                got: req.apiVersion ?? 0,
                expected: APIContract.version,
            )
        }
        guard PairingCode.isValid(req.code) else {
            throw PairingError.invalidCode
        }
        let joinerHostId = req.hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joinerHostId.isEmpty else {
            throw PairingError.invalidPayload("hostId is required")
        }
        if joinerHostId == input.issuerHostId {
            throw PairingError.selfPair
        }

        let presented = try parsePresentedCertificate(
            pem: req.deviceCertificatePEM,
            caPEM: req.caCertificatePEM,
            expectedHostId: joinerHostId,
            now: input.now,
        )

        let csr = try validateCSR(req.csrPEM)
        try bindCSR(csr, to: presented.spki)

        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(
                dataDir: input.dataDir,
                hostId: input.issuerHostId,
                now: input.now,
            )
        } catch {
            throw PairingError.unavailable(
                "Home CA is unavailable; local runtime continues: \(error.localizedDescription)",
            )
        }

        let store = offers ?? PairingOfferStore(dataDir: input.dataDir)
        let pinStore = pins ?? PeerPinStore(dataDir: input.dataDir)
        if let replayed = try replaySameJoinerIfConsumed(
            store: store,
            pins: pinStore,
            code: req.code,
            joinerHostId: joinerHostId,
            fingerprint: presented.fingerprint,
            presentedSPKI: presented.spki,
            csrPEM: req.csrPEM,
            material: material,
            now: input.now,
        ) {
            return attachIdentity(replayed, input: input)
        }
        let consumed = try store.consume(code: req.code, now: input.now)
        let issued: IssuedDeviceCertificate
        do {
            issued = try issueAndPin(
                joinerHostId: joinerHostId,
                csrPEM: req.csrPEM,
                fingerprint: presented.fingerprint,
                material: material,
                now: input.now,
                pins: pinStore,
            )
        } catch {
            do {
                try store.restore(consumed)
            } catch {
                throw PairingError.unavailable(
                    "Unable to restore pairing offer after redeem failure; issue a new code",
                )
            }
            throw error
        }
        return attachIdentity(
            PairingRedeemResponse(
                hostId: input.issuerHostId,
                deviceCertificatePEM: material.deviceCertificatePEM,
                deviceFingerprint: material.deviceFingerprint,
                caCertificatePEM: material.caCertificatePEM,
                caFingerprint: material.caFingerprint,
                issuedCertificatePEM: issued.certificatePEM,
                issuedFingerprint: issued.fingerprint,
                agentPort: consumed.agentPort,
            ),
            input: input,
        )
    }

    /// First local admin with a password set. Used by redeem to attach identity.
    public static func loadAdminUser(db: DatabasePool) throws -> PairingAdminUser? {
        let user = try db.read { db in
            try User
                .filter(User.Columns.password != "")
                .order(User.Columns.createdAt.asc)
                .fetchOne(db)
        }
        guard let user else { return nil }
        return PairingAdminUser(
            id: user.id,
            username: user.username,
            passwordHash: user.password,
        )
    }

    public static func resolveJoinPayload(_ request: PairingJoinRequest) throws -> PairingPayload {
        // QR host/port/agentPort are the out-of-band redeem target.
        // Typed host/port on the non-QR path would let an unauthenticated
        // setup-window caller aim server-side HTTP redeem at an arbitrary
        // LAN or rebinding host.
        guard let raw = request.qrPayload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw PairingError.invalidPayload("QR payload is required to join")
        }
        return try PairingPayload.parse(raw)
    }

    // MARK: - Private

    /// Same joiner may retry after a successful consume (lost 200, local
    /// applyTrust failure) until the offer TTL elapses. The CSR must still
    /// match the pinned Device certificate; a different key is not signed.
    /// A different Device still sees expiredOrUsed.
    private static func replaySameJoinerIfConsumed(
        store: PairingOfferStore,
        pins: PeerPinStore,
        code: String,
        joinerHostId: String,
        fingerprint: String,
        presentedSPKI: [UInt8],
        csrPEM: String,
        material: HomeCertificateMaterial,
        now: Date,
    ) throws -> PairingRedeemResponse? {
        guard let offer = try store.load(), offer.consumedAt != nil else {
            return nil
        }
        if let expires = iso8601.date(from: offer.expiresAt), now >= expires {
            throw PairingError.expiredOrUsed
        }
        let incoming = PairingCode.hash(code)
        guard PairingCode.hashesEqual(incoming, offer.codeHash) else {
            return nil
        }
        guard let pin = try pins.pin(forHostId: joinerHostId),
              pin.fingerprint == fingerprint.lowercased() else {
            return nil
        }
        let csr = try validateCSR(csrPEM)
        try bindCSR(csr, to: presentedSPKI)
        let issued = try issuePeerCertificate(
            joinerHostId: joinerHostId,
            csrPEM: csrPEM,
            material: material,
            now: now,
        )
        return PairingRedeemResponse(
            hostId: material.hostId,
            deviceCertificatePEM: material.deviceCertificatePEM,
            deviceFingerprint: material.deviceFingerprint,
            caCertificatePEM: material.caCertificatePEM,
            caFingerprint: material.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            agentPort: offer.agentPort,
        )
    }

    /// Shared login material for the joiner (PAS-81). Reads `dataDir/jwt-secret`
    /// when RedeemInput does not pass one; never generates a secret here.
    static func attachIdentity(
        _ response: PairingRedeemResponse,
        input: RedeemInput,
    ) -> PairingRedeemResponse {
        var copy = response
        let secret = input.jwtSecret ?? Config.loadJWTSecret(from: input.dataDir)
        if let secret, !secret.isEmpty {
            copy.jwtSecret = secret
        }
        if let admin = input.adminUser,
           !admin.id.isEmpty,
           !admin.username.isEmpty,
           !admin.passwordHash.isEmpty {
            copy.adminUser = admin
        }
        return copy
    }

    private static func issuePeerCertificate(
        joinerHostId: String,
        csrPEM: String,
        material: HomeCertificateMaterial,
        now: Date,
    ) throws -> IssuedDeviceCertificate {
        do {
            return try HomeCAService.issueDeviceCert(
                hostId: joinerHostId,
                csrPEM: csrPEM,
                material: material,
                now: now,
            )
        } catch let error as HomeCAError {
            throw PairingError.invalidCSR(error.localizedDescription)
        } catch {
            throw PairingError.unavailable(
                "Unable to issue Device certificate: \(error.localizedDescription)",
            )
        }
    }

    private static func issueAndPin(
        joinerHostId: String,
        csrPEM: String,
        fingerprint: String,
        material: HomeCertificateMaterial,
        now: Date,
        pins: PeerPinStore,
    ) throws -> IssuedDeviceCertificate {
        let issued = try issuePeerCertificate(
            joinerHostId: joinerHostId,
            csrPEM: csrPEM,
            material: material,
            now: now,
        )
        do {
            try pins.pin(hostId: joinerHostId, fingerprint: fingerprint, now: now)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist peer pin: \(error.localizedDescription)",
            )
        }
        return issued
    }

    private struct PresentedCertificate {
        let fingerprint: String
        let spki: [UInt8]
    }

    private static func bindCSR(_ csr: CertificateSigningRequest, to presentedSPKI: [UInt8]) throws {
        guard Array(csr.publicKey.subjectPublicKeyInfoBytes) == presentedSPKI else {
            throw PairingError.invalidCSR(
                "CSR public key does not match Device certificate",
            )
        }
    }

    private static func validateCSR(_ pem: String) throws -> CertificateSigningRequest {
        let csr: CertificateSigningRequest
        do {
            csr = try CertificateSigningRequest(pemEncoded: pem)
        } catch {
            throw PairingError.invalidCSR("Unable to parse CSR")
        }
        guard csr.publicKey.isValidSignature(csr.signature, for: csr) else {
            throw PairingError.invalidCSR("CSR signature is invalid")
        }
        return csr
    }

    private static func parsePresentedCertificate(
        pem: String,
        caPEM: String,
        expectedHostId: String,
        now: Date,
    ) throws -> PresentedCertificate {
        let cert: Certificate
        do {
            cert = try Certificate(pemEncoded: pem)
        } catch {
            throw PairingError.invalidDeviceCertificate("Unable to parse PEM")
        }
        if now < cert.notValidBefore || now > cert.notValidAfter {
            throw PairingError.invalidDeviceCertificate("Certificate is expired")
        }
        guard let sanHostId = DeviceTrust.hostId(from: cert) else {
            throw PairingError.invalidDeviceCertificate("Missing barkvisor://device SAN")
        }
        guard sanHostId == expectedHostId else {
            throw PairingError.invalidDeviceCertificate("SAN hostId does not match request")
        }
        let ca = try parsePresentedCA(caPEM, now: now)
        guard !isCertificateAuthority(cert) else {
            throw PairingError.invalidDeviceCertificate("Device certificate must not be a CA")
        }
        guard DeviceTrust.isIssuedByHomeCA(leaf: cert, ca: ca) else {
            throw PairingError.invalidDeviceCertificate(
                "Device certificate is not signed by the joiner Home CA",
            )
        }
        let fingerprint: String
        do {
            fingerprint = try DeviceTrust.fingerprint(certificate: cert)
        } catch {
            throw PairingError.invalidDeviceCertificate("Unable to fingerprint certificate")
        }
        return PresentedCertificate(
            fingerprint: fingerprint,
            spki: Array(cert.publicKey.subjectPublicKeyInfoBytes),
        )
    }

    private static func parsePresentedCA(_ pem: String, now: Date) throws -> Certificate {
        let ca: Certificate
        do {
            ca = try Certificate(pemEncoded: pem)
        } catch {
            throw PairingError.invalidDeviceCertificate("Unable to parse Home CA certificate")
        }
        if now < ca.notValidBefore || now > ca.notValidAfter {
            throw PairingError.invalidDeviceCertificate("Home CA certificate is expired")
        }
        guard isCertificateAuthority(ca) else {
            throw PairingError.invalidDeviceCertificate("Presented CA is not a Home CA")
        }
        guard ca.publicKey.isValidSignature(ca.signature, for: ca) else {
            throw PairingError.invalidDeviceCertificate("Home CA certificate is not self-signed")
        }
        return ca
    }

    private static func isCertificateAuthority(_ certificate: Certificate) -> Bool {
        let constraints: BasicConstraints?
        do {
            constraints = try certificate.extensions.basicConstraints
        } catch {
            return false
        }
        guard let constraints, case .isCertificateAuthority = constraints else {
            return false
        }
        return true
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
        throw PairingError.invalidPayload(
            "No advertisable host; set advertisedHost or connect to a network",
        )
    }
}
