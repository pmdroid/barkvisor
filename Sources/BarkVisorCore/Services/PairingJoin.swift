import Foundation
import X509

extension PairingService {
    public static func applyTrust(
        response: PairingRedeemResponse,
        expected: PairingPayload,
        dataDir: URL,
        localHostId: String,
        now: Date = Date(),
        pins: PeerPinStore? = nil,
    ) throws -> PairingJoinResponse {
        if response.hostId != expected.hostId {
            throw PairingError.fingerprintMismatch
        }
        if response.deviceFingerprint.lowercased() != expected.fingerprint.lowercased() {
            throw PairingError.fingerprintMismatch
        }
        guard (1 ... 65_535).contains(response.agentPort) else {
            throw PairingError.invalidPayload("Issuer returned an invalid agentPort")
        }
        if response.agentPort != expected.agentPort {
            throw PairingError.invalidPayload("Issuer agentPort does not match the pairing code")
        }
        if response.hostId == localHostId {
            throw PairingError.selfPair
        }
        if response.apiVersion != APIContract.version {
            throw PairingError.incompatibleAPIVersion(
                got: response.apiVersion,
                expected: APIContract.version,
            )
        }

        try validateRedeemMaterial(response, localHostId: localHostId, now: now)

        let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
        do {
            try pinStore.pin(
                hostId: response.hostId,
                fingerprint: response.deviceFingerprint,
                now: now,
            )
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist peer pin: \(error.localizedDescription)",
            )
        }

        let receipt = PairingPeerReceipt(
            peerHostId: response.hostId,
            peerFingerprint: response.deviceFingerprint,
            caCertificatePEM: response.caCertificatePEM,
            caFingerprint: response.caFingerprint,
            issuedCertificatePEM: response.issuedCertificatePEM,
            issuedFingerprint: response.issuedFingerprint,
            agentPort: response.agentPort,
            pairedAt: iso8601.string(from: now),
        )
        try persistReceipt(receipt, dataDir: dataDir)

        return PairingJoinResponse(
            peerHostId: response.hostId,
            peerFingerprint: response.deviceFingerprint,
            issuedFingerprint: response.issuedFingerprint,
            agentPort: response.agentPort,
        )
    }

    public static func join(
        request: PairingJoinRequest,
        dataDir: URL,
        hostId: String,
        now: Date = Date(),
        client: any PairingHTTPClient,
        pins: PeerPinStore? = nil,
    ) async throws -> PairingJoinResponse {
        let payload = try resolveJoinPayload(request)
        guard let host = payload.host, !host.isEmpty else {
            throw PairingError.invalidPayload("Pairing host is missing from the QR / request")
        }
        if payload.hostId == hostId {
            throw PairingError.selfPair
        }

        // Validate the redeem target (string encodings + DNS) before reading
        // or POSTing joiner CSR / Device cert / Home CA.
        let url = try PairingPayload.redeemURL(host: host, port: payload.port)

        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId, now: now)
        } catch {
            throw PairingError.unavailable(
                "Home CA is unavailable; local runtime continues: \(error.localizedDescription)",
            )
        }

        let csrPEM: String
        do {
            csrPEM = try HomeCAService.makeDeviceCSR(hostId: hostId, keyPEM: material.deviceKeyPEM)
        } catch {
            throw PairingError.unavailable(
                "Unable to build pairing CSR: \(error.localizedDescription)",
            )
        }

        let body = PairingRedeemRequest(
            code: payload.code,
            hostId: hostId,
            csrPEM: csrPEM,
            deviceCertificatePEM: material.deviceCertificatePEM,
            caCertificatePEM: material.caCertificatePEM,
        )
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw PairingError.unavailable("Unable to encode redeem request")
        }
        let http: PairingHTTPResponse
        do {
            http = try await client.postJSON(url: url, body: encoded)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.redeemFailed(
                status: 502,
                reason: "Unable to reach the other Device: \(error.localizedDescription)",
            )
        }

        guard (200 ... 299).contains(http.status) else {
            let reason = decodeErrorReason(http.body) ?? "Pairing redeem failed"
            throw PairingError.redeemFailed(status: http.status, reason: reason)
        }

        let remote: PairingRedeemResponse
        do {
            remote = try JSONDecoder().decode(PairingRedeemResponse.self, from: http.body)
        } catch {
            throw PairingError.invalidPayload("Issuer returned an invalid pairing response")
        }

        return try applyTrust(
            response: remote,
            expected: payload,
            dataDir: dataDir,
            localHostId: hostId,
            now: now,
            pins: pins,
        )
    }

    public static func receiptURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(receiptFileName)
    }

    public static func loadReceipt(dataDir: URL) throws -> PairingPeerReceipt? {
        let url = receiptURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PairingPeerReceipt.self, from: data)
    }

    static func persistReceipt(_ receipt: PairingPeerReceipt, dataDir: URL) throws {
        let url = receiptURL(in: dataDir)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(receipt)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path,
            )
        } catch {
            throw PairingError.unavailable(
                "Unable to persist pairing receipt: \(error.localizedDescription)",
            )
        }
    }

    static func decodeErrorReason(_ data: Data) -> String? {
        struct Envelope: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.reason
    }

    /// Bind redeem PEMs to the QR fingerprint and check the issuer / issued
    /// chain before persisting attacker-controlled CA or leaf material.
    static func validateRedeemMaterial(
        _ response: PairingRedeemResponse,
        localHostId: String,
        now: Date = Date(),
    ) throws {
        let deviceCert = try parseTrustCertificate(
            response.deviceCertificatePEM,
            reason: "Unable to parse issuer Device certificate",
        )
        try rejectExpired(deviceCert, now: now, reason: "Issuer Device certificate is expired")
        let deviceFingerprint = try fingerprintOrThrow(deviceCert)
        if deviceFingerprint != response.deviceFingerprint.lowercased() {
            throw PairingError.fingerprintMismatch
        }
        guard DeviceTrust.hostId(from: deviceCert) == response.hostId else {
            throw PairingError.invalidDeviceCertificate(
                "Issuer Device certificate SAN does not match hostId",
            )
        }

        let caCert = try parseTrustCertificate(
            response.caCertificatePEM,
            reason: "Unable to parse Home CA certificate",
        )
        try rejectExpired(caCert, now: now, reason: "Home CA certificate is expired")
        let caFingerprint = try fingerprintOrThrow(caCert)
        if caFingerprint != response.caFingerprint.lowercased() {
            throw PairingError.fingerprintMismatch
        }
        guard DeviceTrust.isIssuedByHomeCA(leaf: deviceCert, ca: caCert) else {
            throw PairingError.invalidDeviceCertificate(
                "Issuer Device certificate is not signed by the returned CA",
            )
        }

        let issuedCert = try parseTrustCertificate(
            response.issuedCertificatePEM,
            reason: "Unable to parse issued Device certificate",
        )
        try rejectExpired(issuedCert, now: now, reason: "Issued Device certificate is expired")
        let issuedFingerprint = try fingerprintOrThrow(issuedCert)
        if issuedFingerprint != response.issuedFingerprint.lowercased() {
            throw PairingError.fingerprintMismatch
        }
        guard DeviceTrust.isIssuedByHomeCA(leaf: issuedCert, ca: caCert) else {
            throw PairingError.invalidDeviceCertificate(
                "Issued Device certificate is not signed by the returned CA",
            )
        }
        guard DeviceTrust.hostId(from: issuedCert) == localHostId else {
            throw PairingError.invalidDeviceCertificate(
                "Issued certificate SAN does not match this Device",
            )
        }
    }

    private static func rejectExpired(_ certificate: Certificate, now: Date, reason: String) throws {
        if now < certificate.notValidBefore || now > certificate.notValidAfter {
            throw PairingError.invalidDeviceCertificate(reason)
        }
    }

    private static func parseTrustCertificate(_ pem: String, reason: String) throws -> Certificate {
        do {
            return try Certificate(pemEncoded: pem)
        } catch {
            throw PairingError.invalidDeviceCertificate(reason)
        }
    }

    private static func fingerprintOrThrow(_ certificate: Certificate) throws -> String {
        do {
            return try DeviceTrust.fingerprint(certificate: certificate)
        } catch {
            throw PairingError.invalidDeviceCertificate("Unable to fingerprint certificate")
        }
    }
}
