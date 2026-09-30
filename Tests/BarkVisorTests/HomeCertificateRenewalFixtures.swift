import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Shared fixtures for the certificate-renewal suites: a real pair of paired
/// Devices, and a stub for the member plane.
enum RenewalFixtures {
    static func isolatedDir(_ label: String = "renew") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Issue a code, redeem it as the joiner, and apply the trust locally:
    /// the issuer keeps membership and pins, the joiner keeps the receipt.
    static func pair(
        issuerDir: URL,
        joinerDir: URL,
        issuerId: String,
        joinerId: String,
        now: Date = Date(),
        agentHost: String = "192.168.0.8",
    ) async throws -> (issuer: HomeCertificateMaterial, joiner: HomeCertificateMaterial, issued: PairingRedeemResponse) {
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId, now: now)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId, now: now)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let offered = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: agentHost,
                advertisedHosts: [agentHost],
                now: now,
            ),
            offers: offers,
        )
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: PairingRedeemRequest(
                    code: offered.code,
                    hostId: joinerId,
                    csrPEM: HomeCAService.makeDeviceCSR(
                        hostId: joinerId,
                        keyPEM: joiner.deviceKeyPEM,
                    ),
                    deviceCertificatePEM: joiner.deviceCertificatePEM,
                    caCertificatePEM: joiner.caCertificatePEM,
                    agentHost: "192.168.0.9",
                ),
                now: now,
            ),
            offers: offers,
        )
        let payload = PairingPayload(
            code: offered.code,
            host: agentHost,
            port: Config.port,
            agentPort: Config.agentPort,
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )
        _ = try await PairingService.applyTrust(
            response: remote,
            expected: payload,
            dataDir: joinerDir,
            localHostId: joinerId,
            now: now,
        )
        return (issuer, joiner, remote)
    }

    // MARK: - Fixtures

    struct RenewalFixture {
        let issuerDir: URL
        let joinerDir: URL
        let issuerId: String
        let joinerId: String
        let issuer: HomeCertificateMaterial
        let joiner: HomeCertificateMaterial
        var issued: PairingRedeemResponse
        let csrPEM: String

        func renew(request: AgentCertificateRenewRequest) throws -> AgentCertificateRenewResponse {
            try issue(dirs: self, request: request)
        }
    }

    /// Paired Home whose issued leaf is already inside the renewal window,
    /// unless `fresh` asks for a leaf that is not due yet.
    static func renewalFixture(fresh: Bool = false) async throws -> RenewalFixture {
        let issuerDir = try isolatedDir("iss")
        let joinerDir = try isolatedDir("join")
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let (issuer, joiner, issued) = try await pair(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
        )
        let fixture = try RenewalFixture(
            issuerDir: issuerDir,
            joinerDir: joinerDir,
            issuerId: issuerId,
            joinerId: joinerId,
            issuer: issuer,
            joiner: joiner,
            issued: issued,
            csrPEM: HomeCAService.makeDeviceCSR(
                hostId: joinerId,
                keyPEM: joiner.deviceKeyPEM,
            ),
        )
        return fresh ? fixture : try withShortLivedLeaf(fixture)
    }

    /// Replace the pairing leaf with one that expires inside the renewal
    /// window, the state a long-paired Device reaches near the end of the
    /// year. Both sides record the new leaf exactly as a renewal would.
    static func withShortLivedLeaf(
        _ fixture: RenewalFixture,
    ) throws -> RenewalFixture {
        let soon = try HomeCAService.issueDeviceCert(
            hostId: fixture.joinerId,
            csrPEM: fixture.csrPEM,
            material: fixture.issuer,
            now: Date(),
            validity: HomeCertificateRenewal.renewalWindow / 2,
        )
        try HomeMembershipAuthority(dataDir: fixture.issuerDir).admitMemberCertificate(
            hostId: fixture.joinerId,
            fingerprints: [fixture.joiner.deviceFingerprint, soon.fingerprint],
            now: Date(),
            pins: PeerPinStore(dataDir: fixture.issuerDir),
        )
        var receipt = try #require(try PairingService.loadReceipt(dataDir: fixture.joinerDir))
        receipt.issuedCertificatePEM = soon.certificatePEM
        receipt.issuedFingerprint = soon.fingerprint
        try PairingService.persistReceipt(receipt, dataDir: fixture.joinerDir)
        #expect(
            HomeCertificateRenewal.renewalDue(
                issuedCertificatePEM: soon.certificatePEM,
                now: Date(),
            ),
        )
        var copy = fixture
        copy.issued.issuedCertificatePEM = soon.certificatePEM
        copy.issued.issuedFingerprint = soon.fingerprint
        return copy
    }

    static func issue(
        dirs: RenewalFixture,
        request: AgentCertificateRenewRequest,
    ) throws -> AgentCertificateRenewResponse {
        try HomeCertificateRenewal.issueReplacement(
            dataDir: dirs.issuerDir,
            issuerHostId: dirs.issuerId,
            peer: AgentPeerIdentity(
                hostId: dirs.joinerId,
                fingerprint: dirs.issued.issuedFingerprint,
                trust: "home-ca",
            ),
            presentedCertificatePEM: dirs.issued.issuedCertificatePEM,
            request: request,
        )
    }

    /// Renew on behalf of a member that presents `presented` right now.
    static func issue(
        issuerDir: URL,
        issuerId: String,
        joinerId: String,
        presentedPEM: String,
        presentedFingerprint: String,
        csrPEM: String,
    ) throws -> AgentCertificateRenewResponse {
        try HomeCertificateRenewal.issueReplacement(
            dataDir: issuerDir,
            issuerHostId: issuerId,
            peer: AgentPeerIdentity(
                hostId: joinerId,
                fingerprint: presentedFingerprint,
                trust: "home-ca",
            ),
            presentedCertificatePEM: presentedPEM,
            request: AgentCertificateRenewRequest(hostId: joinerId, csrPEM: csrPEM),
        )
    }

    static func memberClient(
        material: HomeCertificateMaterial,
        receipt: PairingPeerReceipt,
    ) -> AgentMTLSClient {
        AgentMTLSClient(
            material: material,
            presentationCertificatePEM: receipt.issuedCertificatePEM,
            trustCertificatePEMs: AgentPlaneCertificates.trustCertificatePEMs(
                material: material,
                receipt: receipt,
            ),
        )
    }

    final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = 0

        func increment() {
            lock.lock()
            stored += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    /// Canned member-plane answer, including the 404 a Home without the renewal
    /// route returns.
    struct StubRenewalClient: HomeDeviceProxyClient {
        let status: Int
        let body: Data
        let failure: String?

        init(status: Int, body: Data, failure: String? = nil) {
            self.status = status
            self.body = body
            self.failure = failure
        }

        static func failing() -> Self {
            StubRenewalClient(status: 0, body: Data(), failure: "offline")
        }

        func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
            if let failure {
                throw HomeDeviceProxyError.unreachable(failure)
            }
            return HomeDeviceProxyResponse(status: status, body: body)
        }
    }
}
