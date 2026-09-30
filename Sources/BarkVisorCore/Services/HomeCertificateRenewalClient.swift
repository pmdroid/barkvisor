import Foundation
import X509

/// What a renewal attempt did. The member keeps presenting its existing
/// pairing-issued certificate in every case except ``renewed(fingerprint:validUntil:)``,
/// so a Home that cannot renew never leaves this Device without an identity.
public enum CertificateRenewalOutcome: Sendable, Equatable {
    /// This Device is not paired; there is nothing to renew.
    case notPaired
    /// The issued leaf is still comfortably valid.
    case notDue(validUntil: Date)
    /// A new Home-issued leaf is persisted and presented from now on.
    case renewed(fingerprint: String, validUntil: Date)
    /// The Home predates the renewal exchange (1.0.0-alpha.13 answers 404).
    case unsupportedIssuer
    /// The Home could not be reached, or the answer could not be read.
    case issuerUnreachable(String)
    /// The Home refused: revoked member, wrong identity, unusable answer.
    case denied(String)
    /// Local material or the exchange itself is not usable.
    case failed(String)

    public var renewedFingerprint: String? {
        if case let .renewed(fingerprint, _) = self { return fingerprint }
        return nil
    }
}

/// Retry spacing after an attempt. A Home that does not know the exchange is
/// not going to grow it while this Device is paired, so it is polled daily
/// instead of on the tight offline backoff.
public enum CertificateRenewalRetryPolicy {
    public static let unsupportedIssuerDelay: TimeInterval = 24 * 60 * 60
    public static let deniedDelay: TimeInterval = 60 * 60
    public static let maximumUnreachableDelay: TimeInterval = 6 * 60 * 60
    public static let baseUnreachableDelay: TimeInterval = 5 * 60

    public static func delay(after outcome: CertificateRenewalOutcome, failedAttempts: Int) -> TimeInterval {
        switch outcome {
        case .notPaired, .notDue, .renewed:
            return 0
        case .unsupportedIssuer:
            return unsupportedIssuerDelay
        case .denied, .failed:
            return deniedDelay
        case .issuerUnreachable:
            let attempt = max(1, min(failedAttempts, 8))
            return min(baseUnreachableDelay * Double(1 << (attempt - 1)), maximumUnreachableDelay)
        }
    }
}

/// Member side of the renewal exchange (barkvisor#740).
public enum HomeCertificateRenewalClient {
    /// Ask the issuing Home for a replacement leaf and persist it.
    ///
    /// The receipt is the only file this touches: host identity, the device
    /// key, the pinned Home certificate, login material, and SQLite are left
    /// exactly as they were, so a renewal cannot change who this Device is.
    public static func renew(
        dataDir: URL,
        hostId: String,
        client: any HomeDeviceProxyClient,
        now: Date = Date(),
        devices: DeviceRegistry? = nil,
    ) async -> CertificateRenewalOutcome {
        let prepared: (receipt: PairingPeerReceipt, material: HomeCertificateMaterial, url: URL, body: Data)
        switch prepare(dataDir: dataDir, hostId: hostId, now: now, devices: devices) {
        case let .ready(value):
            prepared = value
        case let .outcome(outcome):
            return outcome
        }

        let response: HomeDeviceProxyResponse
        do {
            response = try await client.send(
                HomeDeviceProxyRequest(
                    method: "POST",
                    url: prepared.url,
                    headers: [("Content-Type", "application/json")],
                    body: prepared.body,
                ),
            )
        } catch {
            return .issuerUnreachable(error.localizedDescription)
        }

        switch response.status {
        case 404, 405:
            // A Home that predates the exchange (1.0.0-alpha.13) has no such
            // route. The certificate this Device already holds stays in place.
            return .unsupportedIssuer
        case 401, 403:
            return .denied(Self.reason(in: response.body) ?? "The Home refused the renewal")
        case 200 ..< 300:
            break
        default:
            return .issuerUnreachable(
                Self.reason(in: response.body) ?? "The Home answered HTTP \(response.status)",
            )
        }

        let renewal: AgentCertificateRenewResponse
        do {
            renewal = try JSONDecoder().decode(AgentCertificateRenewResponse.self, from: response.body)
        } catch {
            return .failed("The Home returned an invalid renewal response")
        }
        do {
            let leaf = try validate(renewal, receipt: prepared.receipt, material: prepared.material, now: now)
            try persist(renewal, previous: prepared.receipt, dataDir: dataDir, now: now)
            return .renewed(fingerprint: renewal.fingerprint, validUntil: leaf.notValidAfter)
        } catch let error as CertificateRenewalError {
            if case .memberDenied = error {
                return .denied(error.errorDescription ?? "The Home refused the renewal")
            }
            return .failed(error.errorDescription ?? "The renewal response was not usable")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private enum Preparation {
        case ready(
            receipt: PairingPeerReceipt,
            material: HomeCertificateMaterial,
            url: URL,
            body: Data,
        )
        case outcome(CertificateRenewalOutcome)
    }

    private static func prepare(
        dataDir: URL,
        hostId: String,
        now: Date,
        devices: DeviceRegistry?,
    ) -> Preparation {
        let receipt: PairingPeerReceipt
        do {
            guard let existing = try PairingService.loadReceipt(dataDir: dataDir) else {
                return .outcome(.notPaired)
            }
            receipt = existing
        } catch {
            return .outcome(.failed("Pairing receipt is unreadable: \(error.localizedDescription)"))
        }
        let material: HomeCertificateMaterial
        do {
            material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId, now: now)
        } catch {
            return .outcome(.failed("Local Home CA is unavailable: \(error.localizedDescription)"))
        }
        do {
            // The renewal is only valid for the key the Home already pinned. A
            // receipt that no longer matches the device key cannot be renewed;
            // it needs a new pairing, not a new certificate.
            _ = try AgentPlaneCertificates.presentationCertificatePEM(
                material: material,
                receipt: receipt,
            )
        } catch {
            return .outcome(
                .failed("Pairing receipt does not match this Device key; re-pair the Device"),
            )
        }
        let csrPEM: String
        do {
            csrPEM = try HomeCAService.makeDeviceCSR(hostId: hostId, keyPEM: material.deviceKeyPEM)
        } catch {
            return .outcome(.failed("Unable to build the renewal CSR: \(error.localizedDescription)"))
        }
        let url: URL
        do {
            url = try issuerURL(dataDir: dataDir, receipt: receipt, devices: devices)
        } catch let error as CertificateRenewalError {
            return .outcome(.failed(error.errorDescription ?? "Home address is unknown"))
        } catch {
            return .outcome(.failed("Home address is unknown: \(error.localizedDescription)"))
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(AgentCertificateRenewRequest(hostId: hostId, csrPEM: csrPEM))
        } catch {
            return .outcome(.failed("Unable to encode the renewal request"))
        }
        return .ready(receipt: receipt, material: material, url: url, body: body)
    }

    /// Endpoint URL of the issuing Home's agent plane.
    public static func issuerURL(
        dataDir: URL,
        receipt: PairingPeerReceipt,
        devices: DeviceRegistry? = nil,
    ) throws -> URL {
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        guard let record = try store.record(forHostId: receipt.peerHostId),
              let host = record.agentHost,
              !host.isEmpty
        else {
            throw CertificateRenewalError.invalidRequest(
                "The Home address is not known; re-pair this Device",
            )
        }
        return try HomeDeviceProxy.memberURL(
            host: host,
            port: record.agentPort,
            path: HomeCertificateRenewal.endpointPath,
        )
    }

    /// Check that the answer really is a renewal of *this* pairing: the Home
    /// we are paired with, its pinned CA, our own Device id, and our key.
    private static func validate(
        _ renewal: AgentCertificateRenewResponse,
        receipt: PairingPeerReceipt,
        material: HomeCertificateMaterial,
        now: Date,
    ) throws -> Certificate {
        guard renewal.apiVersion == APIContract.version else {
            throw CertificateRenewalError.incompatibleAPIVersion(
                got: renewal.apiVersion,
                expected: APIContract.version,
            )
        }
        guard renewal.hostId.caseInsensitiveCompare(receipt.peerHostId) == .orderedSame else {
            throw CertificateRenewalError.invalidRequest("The renewal came from a different Home")
        }
        // The pinned Home certificate is what proves this Home's identity. A
        // different Home CA is a new Home, not a renewal.
        guard renewal.caFingerprint.lowercased() == receipt.caFingerprint.lowercased() else {
            throw CertificateRenewalError.invalidRequest(
                "The Home certificate changed; re-pair this Device",
            )
        }
        let ca = try parse(renewal.caCertificatePEM, "The Home returned an unreadable CA")
        try require(
            (try? DeviceTrust.fingerprint(certificate: ca))?.lowercased()
                == renewal.caFingerprint.lowercased(),
            "The Home CA does not match its fingerprint",
        )
        let leaf = try parse(
            renewal.certificatePEM,
            "The Home returned an unreadable certificate",
        )
        try require(
            (try? DeviceTrust.fingerprint(certificate: leaf))?.lowercased()
                == renewal.fingerprint.lowercased(),
            "The certificate does not match its fingerprint",
        )
        try require(
            DeviceTrust.isIssuedByHomeCA(leaf: leaf, ca: ca),
            "The certificate is not signed by the Home that answered",
        )
        try require(
            DeviceTrust.hostId(from: leaf)?.caseInsensitiveCompare(material.hostId) == .orderedSame,
            "The certificate names another Device",
        )
        try require(
            AgentPlaneCertificates.certificateMatchesKey(
                renewal.certificatePEM,
                keyPEM: material.deviceKeyPEM,
            ),
            "The certificate does not match this Device key",
        )
        try require(
            now >= leaf.notValidBefore && now <= leaf.notValidAfter,
            "The Home returned an expired certificate",
        )
        if let stated = iso8601.date(from: renewal.notValidAfter),
           abs(stated.timeIntervalSince(leaf.notValidAfter)) > 1 {
            throw CertificateRenewalError.invalidRequest(
                "The certificate expiry does not match the renewal response",
            )
        }
        return leaf
    }

    /// Write the new leaf into the receipt and nothing else.
    private static func persist(
        _ renewal: AgentCertificateRenewResponse,
        previous: PairingPeerReceipt,
        dataDir: URL,
        now: Date,
    ) throws {
        let updated = PairingPeerReceipt(
            peerHostId: previous.peerHostId,
            peerFingerprint: previous.peerFingerprint,
            caCertificatePEM: renewal.caCertificatePEM,
            caFingerprint: renewal.caFingerprint,
            issuedCertificatePEM: renewal.certificatePEM,
            issuedFingerprint: renewal.fingerprint,
            agentPort: previous.agentPort,
            pairedAt: previous.pairedAt,
            legacyJWTSecret: previous.legacyJWTSecret,
            renewedAt: iso8601.string(from: now),
        )
        do {
            try PairingService.persistReceipt(updated, dataDir: dataDir)
        } catch {
            throw CertificateRenewalError.invalidRequest(
                "Unable to persist the renewed certificate: \(error.localizedDescription)",
            )
        }
    }

    private static func parse(_ pem: String, _ reason: String) throws -> Certificate {
        do {
            return try Certificate(pemEncoded: pem)
        } catch {
            throw CertificateRenewalError.invalidRequest(reason)
        }
    }

    private static func require(_ condition: Bool, _ reason: String) throws {
        guard condition else {
            throw CertificateRenewalError.invalidRequest(reason)
        }
    }

    private static func reason(in data: Data) -> String? {
        struct Envelope: Decodable {
            var reason: String?
        }
        return (try? JSONDecoder().decode(Envelope.self, from: data))?.reason
    }
}

/// Drives ``HomeCertificateRenewalClient`` on a timer.
///
/// State is in memory on purpose: a restart clears the backoff and retries
/// immediately, which is what a Device that was offline or restarting should
/// do. The durable record of a renewal is the persisted receipt.
public actor HomeCertificateRenewalLoop {
    public typealias ClientProvider = @Sendable () throws -> any HomeDeviceProxyClient

    public static let defaultInterval: TimeInterval = 6 * 60 * 60

    private let dataDir: URL
    private let hostId: String
    private let clientProvider: ClientProvider
    private let onRenewed: @Sendable () async -> Void
    private var nextAttemptAt: Date?
    private var failedAttempts = 0

    public init(
        dataDir: URL,
        hostId: String,
        clientProvider: @escaping ClientProvider,
        onRenewed: @escaping @Sendable () async -> Void = {},
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.clientProvider = clientProvider
        self.onRenewed = onRenewed
    }

    /// Run one attempt unless the backoff has not elapsed. `nil` means the
    /// timer fired early and there was nothing to do.
    @discardableResult
    public func tick(now: Date = Date()) async -> CertificateRenewalOutcome? {
        if let nextAttemptAt, now < nextAttemptAt { return nil }
        guard let receipt = try? PairingService.loadReceipt(dataDir: dataDir) else {
            nextAttemptAt = nil
            failedAttempts = 0
            return .notPaired
        }
        if !HomeCertificateRenewal.renewalDue(
            issuedCertificatePEM: receipt.issuedCertificatePEM,
            now: now,
        ) {
            nextAttemptAt = nil
            failedAttempts = 0
            return .notDue(validUntil: Self.validity(of: receipt.issuedCertificatePEM))
        }
        let client: any HomeDeviceProxyClient
        do {
            client = try clientProvider()
        } catch {
            record(.issuerUnreachable(error.localizedDescription), now: now)
            return nil
        }
        let outcome = await HomeCertificateRenewalClient.renew(
            dataDir: dataDir,
            hostId: hostId,
            client: client,
            now: now,
        )
        record(outcome, now: now)
        if outcome.renewedFingerprint != nil {
            await onRenewed()
        }
        return outcome
    }

    /// Seconds until the next attempt may run; 0 when the next tick may try.
    public func delayUntilNextAttempt(now: Date = Date()) -> TimeInterval {
        guard let nextAttemptAt else { return 0 }
        return max(0, nextAttemptAt.timeIntervalSince(now))
    }

    private func record(_ outcome: CertificateRenewalOutcome, now: Date) {
        switch outcome {
        case .notPaired, .notDue, .renewed:
            failedAttempts = 0
            nextAttemptAt = nil
        case .unsupportedIssuer, .issuerUnreachable, .denied, .failed:
            failedAttempts += 1
            nextAttemptAt = now.addingTimeInterval(
                CertificateRenewalRetryPolicy.delay(after: outcome, failedAttempts: failedAttempts),
            )
        }
    }

    private static func validity(of pem: String) -> Date {
        (try? Certificate(pemEncoded: pem).notValidAfter) ?? Date.distantPast
    }
}
