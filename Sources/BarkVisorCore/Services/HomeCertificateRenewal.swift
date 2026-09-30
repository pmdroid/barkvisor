import Foundation
import X509

/// Replacement of a pairing-issued Device certificate (barkvisor#740).
///
/// `AgentPlaneCertificates.presentationCertificatePEM` presents the leaf the
/// pairing Home issued, and the Home records whole-certificate fingerprints
/// for the members it admitted. A local `HomeCAService` renewal cannot stand
/// in for it: that leaf is signed by the Device's own Home CA, so presenting
/// it changes the fingerprint the Home pinned and is not a renewal of the
/// pairing at all. The only valid replacement comes from the issuing Home.
///
/// The exchange runs on the agent plane. The member authenticates with the
/// certificate it already holds, sends a CSR for the *same* key, and the Home
/// issues a new leaf and admits it (membership + pins together). Host id,
/// device key, workloads, and login material are never touched.
public enum HomeCertificateRenewal {
    /// Agent-plane path on the issuing Home. A Home that predates the
    /// exchange (1.0.0-alpha.13) has no such route and answers 404.
    public static let endpointPath = "/api/agent/certificates/renew"
    /// Renew this long before `notValidAfter`, matching the local Home CA so
    /// one window describes both leaves.
    public static let renewalWindow: TimeInterval = HomeCAService.deviceRenewalWindow
    /// Cap on certificates admitted per member: the one presented at pairing,
    /// the one the member presents now, and the one just issued. Keeping the
    /// presented leaf is what makes a renewal whose response was lost
    /// recoverable; the cap stops a long-lived pairing from growing forever.
    public static let admittedFingerprintsPerMember = 3

    /// Issue a replacement leaf for an mTLS-authenticated member.
    ///
    /// `peer` and `presentedCertificatePEM` come from the handshake, so a
    /// request cannot claim another Device's identity. The CSR must be for
    /// the key in the presented certificate, which keeps the member's
    /// identity (and therefore every pin and membership row naming it) valid
    /// across the renewal.
    public static func issueReplacement(
        dataDir: URL,
        issuerHostId: String,
        peer: AgentPeerIdentity,
        presentedCertificatePEM: String,
        request: AgentCertificateRenewRequest,
        now: Date = Date(),
        authority: HomeMembershipAuthority? = nil,
        pins: PeerPinStore? = nil,
    ) throws -> AgentCertificateRenewResponse {
        let target = request.hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else {
            throw CertificateRenewalError.invalidRequest("Device id is required")
        }
        guard target.caseInsensitiveCompare(peer.hostId) == .orderedSame else {
            throw CertificateRenewalError.hostMismatch
        }
        if let version = request.apiVersion, version != APIContract.version {
            throw CertificateRenewalError.incompatibleAPIVersion(
                got: version,
                expected: APIContract.version,
            )
        }

        let presented = try parseCertificate(presentedCertificatePEM, reason: "presented certificate")
        guard now >= presented.notValidBefore, now <= presented.notValidAfter else {
            throw CertificateRenewalError.presentedCertificateExpired
        }
        guard DeviceTrust.hostId(from: presented)?.caseInsensitiveCompare(target) == .orderedSame else {
            throw CertificateRenewalError.invalidRequest(
                "Presented certificate does not name this Device",
            )
        }

        let csr = try parseCSR(request.csrPEM)
        guard Array(csr.publicKey.subjectPublicKeyInfoBytes)
            == Array(presented.publicKey.subjectPublicKeyInfoBytes)
        else {
            throw CertificateRenewalError.keyMismatch
        }

        let ledger = authority ?? HomeMembershipAuthority(dataDir: dataDir)
        switch ledger.authorizeCertificate(
            hostId: target,
            fingerprint: peer.fingerprint,
            localHostId: issuerHostId,
            now: now,
        ) {
        case .allow:
            break
        case let .deny(reason):
            throw CertificateRenewalError.memberDenied(reason)
        }

        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: issuerHostId, now: now)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: target,
            csrPEM: request.csrPEM,
            dataDir: dataDir,
            now: now,
        )
        // Admit the new leaf and keep the one the member still holds, so a
        // retry after a lost response is authorized instead of locking the
        // member out of its own renewal.
        let updated = try ledger.renewMemberCertificate(
            hostId: target,
            superseding: peer.fingerprint,
            issued: issued.fingerprint,
            now: now,
            pins: pins,
        )
        return AgentCertificateRenewResponse(
            hostId: issuerHostId,
            certificatePEM: issued.certificatePEM,
            fingerprint: issued.fingerprint,
            caCertificatePEM: material.caCertificatePEM,
            caFingerprint: material.caFingerprint,
            notValidAfter: iso8601.string(from: issued.notValidAfter),
            membershipRevision: updated.revision,
        )
    }

    /// The set of fingerprints the Home keeps admitting for a member after a
    /// renewal: the certificate the member presented at pairing, the leaf it
    /// presents right now, the leaf just issued, and then as much recent
    /// history as the cap allows.
    ///
    /// Keeping the presented leaf is what makes a lost response recoverable —
    /// the member simply asks again with the certificate it still holds. The
    /// cap keeps a long-lived pairing from growing the record forever.
    public static func admittedFingerprints(
        previous: [String],
        superseding: String,
        issued: String,
        maximum: Int = admittedFingerprintsPerMember,
    ) -> [String] {
        let cap = max(1, maximum)
        var history: [String] = []
        var seen = Set<String>()
        for raw in previous {
            let fingerprint = raw.lowercased()
            guard seen.insert(fingerprint).inserted else { continue }
            history.append(fingerprint)
        }
        let presented = superseding.lowercased()
        var result: [String] = []
        func add(_ fingerprint: String) {
            guard !fingerprint.isEmpty, result.count < cap, !result.contains(fingerprint) else {
                return
            }
            result.append(fingerprint)
        }
        if let base = history.first { add(base) }
        if history.contains(presented) { add(presented) }
        add(issued.lowercased())
        for fingerprint in history.reversed() {
            add(fingerprint)
        }
        return result
    }

    /// True when the issued leaf is inside the renewal window or already
    /// outside its validity. An unreadable leaf is renewed: the exchange is
    /// the only way to replace it.
    public static func renewalDue(issuedCertificatePEM: String, now: Date) -> Bool {
        guard let certificate = try? Certificate(pemEncoded: issuedCertificatePEM) else {
            return true
        }
        return HomeCAService.certificateNeedsRenewal(
            certificate,
            now: now,
            renewalWindow: renewalWindow,
        )
    }

    private static func parseCertificate(_ pem: String, reason: String) throws -> Certificate {
        do {
            return try Certificate(pemEncoded: pem)
        } catch {
            throw CertificateRenewalError.invalidRequest("Unable to parse the \(reason)")
        }
    }

    private static func parseCSR(_ pem: String) throws -> CertificateSigningRequest {
        let csr: CertificateSigningRequest
        do {
            csr = try CertificateSigningRequest(pemEncoded: pem)
        } catch {
            throw CertificateRenewalError.invalidRequest("Unable to parse the renewal CSR")
        }
        guard csr.publicKey.isValidSignature(csr.signature, for: csr) else {
            throw CertificateRenewalError.invalidRequest("Renewal CSR signature is invalid")
        }
        return csr
    }
}

public enum CertificateRenewalError: Error, LocalizedError, Sendable, Equatable {
    case hostMismatch
    case keyMismatch
    case presentedCertificateExpired
    case incompatibleAPIVersion(got: Int, expected: Int)
    case memberDenied(String)
    case invalidRequest(String)

    public var errorDescription: String? {
        switch self {
        case .hostMismatch:
            "Renewal hostId does not match the authenticated Device"
        case .keyMismatch:
            "Renewal CSR does not match the presented Device key"
        case .presentedCertificateExpired:
            "The presented Device certificate has expired"
        case let .incompatibleAPIVersion(got, expected):
            "Incompatible API version \(got) (this Home is \(expected))"
        case let .memberDenied(reason):
            "Home membership denied this renewal: \(reason)"
        case let .invalidRequest(reason):
            reason
        }
    }

    public var barkVisorError: BarkVisorError {
        switch self {
        case .hostMismatch, .keyMismatch, .presentedCertificateExpired,
             .memberDenied:
            .forbidden(errorDescription ?? "Certificate renewal refused")
        case .incompatibleAPIVersion:
            .preconditionFailed(errorDescription ?? "Incompatible API version")
        case let .invalidRequest(reason):
            .badRequest(reason)
        }
    }
}
