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
        db: DatabasePool? = nil,
        keys: JWTKeyCollection? = nil,
        devices: DeviceRegistry? = nil,
    ) async throws -> PairingJoinResponse {
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

        // Identity after receipt/pin so those persist failures leave local
        // JWT secret and admin credentials unchanged. Registry after
        // identity so a failed applySharedIdentity does not list a paired
        // member before shared login is applied.
        try await applySharedIdentity(response, dataDir: dataDir, now: now, db: db, keys: keys)

        try registerPairedDevice(
            dataDir: dataDir,
            hostId: response.hostId,
            fingerprint: response.deviceFingerprint,
            agentHost: expected.host,
            agentPort: response.agentPort,
            now: now,
            devices: devices,
        )

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
        db: DatabasePool? = nil,
        keys: JWTKeyCollection? = nil,
        devices: DeviceRegistry? = nil,
    ) async throws -> PairingJoinResponse {
        let payload = try resolveJoinPayload(request)
        guard let host = payload.host, !host.isEmpty else {
            throw PairingError.invalidPayload("Pairing host is missing from the QR / request")
        }
        if payload.hostId == hostId {
            throw PairingError.selfPair
        }

        // Issuer already consumed this offer on HTTP 200. A local decode /
        // applyTrust failure must retry from this pending body for the same
        // one-time code. A newly issued QR from the same host must redeem
        // again instead of reusing stale material.
        if let pending = loadPendingRedeem(dataDir: dataDir),
           pendingMatches(pending, expected: payload) {
            let result = try await applyTrust(
                response: pending.response,
                expected: payload,
                dataDir: dataDir,
                localHostId: hostId,
                now: now,
                pins: pins,
                db: db,
                keys: keys,
                devices: devices,
            )
            clearPendingRedeem(dataDir: dataDir)
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
            agentHost: PairingAddresses.advertisedIPv4().first,
            agentPort: Config.agentPort,
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
        persistPendingRedeem(remote, code: payload.code, dataDir: dataDir)

        let result = try await applyTrust(
            response: remote,
            expected: payload,
            dataDir: dataDir,
            localHostId: hostId,
            now: now,
            pins: pins,
            db: db,
            keys: keys,
            devices: devices,
        )
        clearPendingRedeem(dataDir: dataDir)
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

    /// True after a pairing receipt was persisted. Receipt can exist before
    /// pin / applySharedIdentity; setup `joined` also requires an admin.
    public static func hasPairedReceipt(dataDir: URL) -> Bool {
        do {
            return try loadReceipt(dataDir: dataDir) != nil
        } catch {
            return false
        }
    }

    static func loadPendingRedeem(dataDir: URL) -> PendingRedeemRecord? {
        let url = pendingRedeemURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingRedeemRecord.self, from: data)
    }

    static func persistPendingRedeem(
        _ response: PairingRedeemResponse,
        code: String,
        dataDir: URL,
    ) {
        let url = pendingRedeemURL(in: dataDir)
        let record = PendingRedeemRecord(codeHash: PairingCode.hash(code), response: response)
        guard let data = try? JSONEncoder().encode(record) else { return }
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

    static func pendingMatches(_ pending: PendingRedeemRecord, expected: PairingPayload) -> Bool {
        PairingCode.hashesEqual(pending.codeHash, PairingCode.hash(expected.code))
            && pending.response.hostId == expected.hostId
            && pending.response.deviceFingerprint.lowercased() == expected.fingerprint.lowercased()
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

    /// Copy issuer login onto this Device. Local SQLite still owns runtime
    /// (PAS-47 / PAS-90); peers are not contacted.
    ///
    /// Persist the JWT secret before upserting admin. A secret write failure
    /// must leave the previous password hash in place so login stays consistent
    /// with the on-disk HMAC key until retry.
    static func applySharedIdentity(
        _ response: PairingRedeemResponse,
        dataDir: URL,
        now: Date,
        db: DatabasePool?,
        keys: JWTKeyCollection?,
    ) async throws {
        if response.adminUser != nil, db == nil {
            throw PairingError.unavailable(
                "Unable to persist shared identity; local runtime continues",
            )
        }
        let secret = response.jwtSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !secret.isEmpty {
            do {
                try Config.persistJWTSecret(secret, to: dataDir)
            } catch {
                throw PairingError.unavailable(
                    "Unable to persist JWT secret: \(error.localizedDescription)",
                )
            }
        }
        if let admin = response.adminUser {
            guard let db else {
                throw PairingError.unavailable(
                    "Unable to persist shared identity; local runtime continues",
                )
            }
            try upsertAdmin(admin, db: db, now: now)
        }
        if !secret.isEmpty, let keys {
            await keys.add(hmac: .init(from: secret), digestAlgorithm: .sha256)
        }
    }

    static func upsertAdmin(_ admin: PairingAdminUser, db: DatabasePool, now: Date) throws {
        let id = admin.id.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = admin.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = admin.passwordHash
        guard !id.isEmpty, !username.isEmpty, !hash.isEmpty else {
            throw PairingError.invalidPayload("Issuer returned incomplete admin identity")
        }
        do {
            try db.write { db in
                if var existing = try User.filter(User.Columns.username == username).fetchOne(db) {
                    existing.password = hash
                    try existing.update(db)
                    return
                }
                if var existing = try User.fetchOne(db, key: id) {
                    existing.username = username
                    existing.password = hash
                    try existing.update(db)
                    return
                }
                try User(
                    id: id,
                    username: username,
                    password: hash,
                    createdAt: iso8601.string(from: now),
                ).insert(db)
            }
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist admin identity: \(error.localizedDescription)",
            )
        }
    }
}
