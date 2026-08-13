import Foundation
import X509

/// Pairing issue + redeem (PAS-45).
///
/// The existing Device issues a short-lived code / QR. The joining Device
/// redeems it and both sides record pairwise pins. Home CA issues a peer
/// cert as trust material on the wire. Local SQLite / QEMU are untouched
/// (PAS-47 / PAS-90).
public enum PairingService {
    public static let defaultTTL: TimeInterval = 10 * 60
    public static let receiptFileName = "pairing-peer.json"

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

        let host = input.advertisedHost.flatMap(PairingPayload.sanitizeHost)
            ?? input.advertisedHosts.first
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
        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(dataDir: input.dataDir, hostId: input.hostId)
        } catch {
            throw PairingError.unavailable(
                "Home CA is unavailable; local runtime continues: \(error.localizedDescription)",
            )
        }
        let host = input.advertisedHost.flatMap(PairingPayload.sanitizeHost)
            ?? input.advertisedHosts.first
        let payload = PairingPayload(
            code: offer.codeDisplay,
            host: host,
            port: input.port,
            agentPort: input.agentPort,
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
            agentPort: input.agentPort,
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

        public init(
            dataDir: URL,
            issuerHostId: String,
            request: PairingRedeemRequest,
            now: Date = Date(),
        ) {
            self.dataDir = dataDir
            self.issuerHostId = issuerHostId
            self.request = request
            self.now = now
        }
    }

    public static func redeem(
        _ input: RedeemInput,
        offers: PairingOfferStore? = nil,
        pins: PeerPinStore? = nil,
    ) throws -> PairingRedeemResponse {
        let req = input.request
        if let version = req.apiVersion, version != APIContract.version {
            throw PairingError.incompatibleAPIVersion(got: version, expected: APIContract.version)
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
            expectedHostId: joinerHostId,
            now: input.now,
        )

        let csr = try validateCSR(req.csrPEM)
        guard Array(csr.publicKey.subjectPublicKeyInfoBytes) == presented.spki else {
            throw PairingError.invalidCSR(
                "CSR public key does not match Device certificate",
            )
        }

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

        let issued: IssuedDeviceCertificate
        do {
            issued = try HomeCAService.issueDeviceCert(
                hostId: joinerHostId,
                csrPEM: req.csrPEM,
                material: material,
                now: input.now,
            )
        } catch let error as HomeCAError {
            throw PairingError.invalidCSR(error.localizedDescription)
        } catch {
            throw PairingError.unavailable(
                "Unable to issue Device certificate: \(error.localizedDescription)",
            )
        }

        let pinStore = pins ?? PeerPinStore(dataDir: input.dataDir)
        do {
            try pinStore.pin(
                hostId: joinerHostId,
                fingerprint: presented.fingerprint,
                now: input.now,
            )
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist peer pin: \(error.localizedDescription)",
            )
        }

        let store = offers ?? PairingOfferStore(dataDir: input.dataDir)
        _ = try store.consume(code: req.code, now: input.now)

        return PairingRedeemResponse(
            hostId: input.issuerHostId,
            deviceCertificatePEM: material.deviceCertificatePEM,
            deviceFingerprint: material.deviceFingerprint,
            caCertificatePEM: material.caCertificatePEM,
            caFingerprint: material.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            agentPort: Config.agentPort,
        )
    }

    public static func resolveJoinPayload(_ request: PairingJoinRequest) throws -> PairingPayload {
        if let raw = request.qrPayload?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            // QR host/port are the out-of-band redeem target. Request
            // overrides would let an unauthenticated join caller redirect
            // redeem at an attacker while keeping the legitimate fingerprint.
            return try PairingPayload.parse(raw)
        }
        guard let code = request.code, PairingCode.isValid(code) else {
            throw PairingError.invalidPayload("Pairing code or QR payload is required")
        }
        guard let host = request.host.flatMap(PairingPayload.sanitizeHost) else {
            throw PairingError.invalidPayload("Pairing host is required when no QR is provided")
        }
        guard let port = request.port, (1 ... 65_535).contains(port) else {
            throw PairingError.invalidPayload("Pairing port is required when no QR is provided")
        }
        guard let hostId = request.hostId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !hostId.isEmpty else {
            throw PairingError.invalidPayload("hostId is required when no QR is provided")
        }
        guard let fingerprint = request.fingerprint?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fingerprint.isEmpty else {
            throw PairingError.invalidPayload("fingerprint is required when no QR is provided")
        }
        return PairingPayload(
            code: code,
            host: host,
            port: port,
            hostId: hostId,
            fingerprint: fingerprint,
        )
    }

    // MARK: - Private

    private struct PresentedCertificate {
        let fingerprint: String
        let spki: [UInt8]
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
}
