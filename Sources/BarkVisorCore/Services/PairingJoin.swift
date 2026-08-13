import Foundation

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
        if response.hostId == localHostId {
            throw PairingError.selfPair
        }
        if response.apiVersion != APIContract.version {
            throw PairingError.incompatibleAPIVersion(
                got: response.apiVersion,
                expected: APIContract.version,
            )
        }

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
            pairedAt: iso8601.string(from: now),
        )
        try persistReceipt(receipt, dataDir: dataDir)

        return PairingJoinResponse(
            peerHostId: response.hostId,
            peerFingerprint: response.deviceFingerprint,
            issuedFingerprint: response.issuedFingerprint,
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
        )
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(body)
        } catch {
            throw PairingError.unavailable("Unable to encode redeem request")
        }

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
}
