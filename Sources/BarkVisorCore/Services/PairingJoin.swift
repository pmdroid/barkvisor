import Foundation
import GRDB
import JWTKit
import X509

extension PairingService {
    public static func applyTrust(
        response: PairingRedeemResponse,
        expected: PairingPayload,
        dataDir: URL,
        localHostId: String,
        now: Date = Date(),
        pins: PeerPinStore? = nil,
        db: (any DatabaseWriter)? = nil,
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
        try persistSharedIdentity(response, dataDir: dataDir, db: db, now: now)

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
        // Receipt first: issuedCertificatePEM / agentPort are required by
        // downstream agent/mTLS. A later pin failure can retry; a pin
        // without a receipt cannot.
        try persistReceipt(receipt, dataDir: dataDir)

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
        db: (any DatabaseWriter)? = nil,
        keys: JWTKeyCollection? = nil,
    ) async throws -> PairingJoinResponse {
        let payload = try resolveJoinPayload(request)
        guard let host = payload.host, !host.isEmpty else {
            throw PairingError.invalidPayload("Pairing host is missing from the QR / request")
        }
        if payload.hostId == hostId {
            throw PairingError.selfPair
        }

        // Issuer already consumed the code on HTTP 200. A local decode /
        // applyTrust failure must retry from this pending body instead of
        // requiring a new pairing code.
        if let pending = loadPendingRedeem(dataDir: dataDir),
           pendingMatches(pending, expected: payload) {
            let result = try applyTrust(
                response: pending,
                expected: payload,
                dataDir: dataDir,
                localHostId: hostId,
                now: now,
                pins: pins,
                db: db,
            )
            clearPendingRedeem(dataDir: dataDir)
            if let keys {
                await JWTSecret.reloadHMAC(keys, secret: pending.jwtSecret)
            }
            return result
        }

        // Validate + pin the contract target (string encodings + DNS) before
        // reading or POSTing joiner CSR / Device cert / Home CA.
        let contractURL = try PairingPayload.contractURL(host: host, port: payload.port)
        try await checkRemoteContract(url: contractURL, client: client)

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
        // Re-resolve and pin immediately before POST so a rebinding name
        // cannot pass the earlier check then connect to a blocked address.
        let url = try PairingPayload.redeemURL(host: host, port: payload.port)
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
        persistPendingRedeem(remote, dataDir: dataDir)

        let result = try applyTrust(
            response: remote,
            expected: payload,
            dataDir: dataDir,
            localHostId: hostId,
            now: now,
            pins: pins,
            db: db,
        )
        clearPendingRedeem(dataDir: dataDir)
        if let keys {
            await JWTSecret.reloadHMAC(keys, secret: remote.jwtSecret)
        }
        return result
    }

    public static func receiptURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(receiptFileName)
    }

    public static func pendingRedeemURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(pendingRedeemFileName)
    }

    public static func loadReceipt(dataDir: URL) throws -> PairingPeerReceipt? {
        let url = receiptURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PairingPeerReceipt.self, from: data)
    }

    static func loadPendingRedeem(dataDir: URL) -> PairingRedeemResponse? {
        let url = pendingRedeemURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PairingRedeemResponse.self, from: data)
    }

    static func persistPendingRedeem(_ response: PairingRedeemResponse, dataDir: URL) {
        let url = pendingRedeemURL(in: dataDir)
        guard let data = try? JSONEncoder().encode(response) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path,
        )
    }

    static func clearPendingRedeem(dataDir: URL) {
        let url = pendingRedeemURL(in: dataDir)
        try? FileManager.default.removeItem(at: url)
    }

    static func pendingMatches(_ pending: PairingRedeemResponse, expected: PairingPayload) -> Bool {
        pending.hostId == expected.hostId
            && pending.deviceFingerprint.lowercased() == expected.fingerprint.lowercased()
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

    /// `GET /api/contract` before redeem so incompatible daemons fail closed
    /// (PAS-78 / Wave 1 synthesis) without exchanging trust material.
    static func checkRemoteContract(url: URL, client: any PairingHTTPClient) async throws {
        let http: PairingHTTPResponse
        do {
            http = try await client.get(url: url)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.redeemFailed(
                status: 502,
                reason: "Unable to reach the other Device: \(error.localizedDescription)",
            )
        }
        guard (200 ... 299).contains(http.status) else {
            let reason = decodeErrorReason(http.body) ?? "Unable to read the other Device API contract"
            throw PairingError.redeemFailed(status: http.status, reason: reason)
        }
        struct ContractProbe: Decodable {
            var apiVersion: Int
        }
        let probe: ContractProbe
        do {
            probe = try JSONDecoder().decode(ContractProbe.self, from: http.body)
        } catch {
            throw PairingError.invalidPayload("Issuer returned an invalid API contract")
        }
        if probe.apiVersion != APIContract.version {
            throw PairingError.incompatibleAPIVersion(
                got: probe.apiVersion,
                expected: APIContract.version,
            )
        }
    }

    static func decodeErrorReason(_ data: Data) -> String? {
        struct Envelope: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.reason
    }

    static func persistSharedIdentity(
        _ response: PairingRedeemResponse,
        dataDir: URL,
        db: (any DatabaseWriter)?,
        now: Date,
    ) throws {
        let admin = try validatedAdmin(response.admin)
        try JWTSecret.replace(response.jwtSecret, dataDir: dataDir)
        guard let db else { return }
        do {
            try upsertAdmin(admin, db: db, now: now)
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist shared admin: \(error.localizedDescription)",
            )
        }
    }

    static func upsertAdmin(
        _ admin: PairingAdminIdentity,
        db: any DatabaseWriter,
        now: Date,
    ) throws {
        try db.write { db in
            if let conflict = try User.filter(User.Columns.username == admin.username).fetchOne(db),
               conflict.id != admin.id {
                try conflict.delete(db)
            }
            if var existing = try User.filter(User.Columns.id == admin.id).fetchOne(db) {
                existing.username = admin.username
                existing.password = admin.passwordHash
                try existing.update(db)
                return
            }
            try User(
                id: admin.id,
                username: admin.username,
                password: admin.passwordHash,
                createdAt: iso8601.string(from: now),
            ).insert(db)
        }
    }

    static func validatedAdmin(_ admin: PairingAdminIdentity) throws -> PairingAdminIdentity {
        let id = admin.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = admin.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let passwordHash = admin.passwordHash.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !username.isEmpty, !passwordHash.isEmpty else {
            throw PairingError.invalidPayload("Issuer admin identity is incomplete")
        }
        return PairingAdminIdentity(id: id, username: username, passwordHash: passwordHash)
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
