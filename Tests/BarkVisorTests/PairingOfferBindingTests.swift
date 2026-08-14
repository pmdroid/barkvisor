import Foundation
import Testing
import X509
@testable import BarkVisorCore

@Suite("Pairing offer binding (PAS-45)")
struct PairingOfferBindingTests {
    private func isolatedDir(_ label: String = "pair-bind") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `consumed code replay rejects a CSR for a different key`() throws {
        let dir = try isolatedDir()
        let joinerDir = try isolatedDir("ja-replay")
        let otherDir = try isolatedDir("jb-replay")
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: joinerDir)
            try? FileManager.default.removeItem(at: otherDir)
        }
        let issuerId = UUID().uuidString
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: UUID().uuidString)
        let other = try HomeCAService.loadOrCreate(dataDir: otherDir, hostId: UUID().uuidString)
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let honest = try redeemRequest(code: issued.code, joiner: joiner)
        let first = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: honest,
            ),
            offers: offers,
        )
        let foreignCSR = try HomeCAService.makeDeviceCSR(
            hostId: joiner.hostId,
            keyPEM: other.deviceKeyPEM,
        )
        #expect(throws: PairingError.self) {
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: dir,
                    issuerHostId: issuerId,
                    request: PairingRedeemRequest(
                        code: issued.code,
                        hostId: joiner.hostId,
                        csrPEM: foreignCSR,
                        deviceCertificatePEM: joiner.deviceCertificatePEM,
                        caCertificatePEM: joiner.caCertificatePEM,
                    ),
                ),
                offers: offers,
            )
        }
        let replayed = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: dir,
                issuerHostId: issuerId,
                request: honest,
            ),
            offers: offers,
        )
        #expect(try PeerPinStore(dataDir: dir).load().count == 1)
        let firstCert = try Certificate(pemEncoded: first.issuedCertificatePEM)
        let replayedCert = try Certificate(pemEncoded: replayed.issuedCertificatePEM)
        let joinerCert = try Certificate(pemEncoded: joiner.deviceCertificatePEM)
        let firstSPKI = Array(firstCert.publicKey.subjectPublicKeyInfoBytes)
        #expect(firstSPKI == Array(replayedCert.publicKey.subjectPublicKeyInfoBytes))
        #expect(firstSPKI == Array(joinerCert.publicKey.subjectPublicKeyInfoBytes))
    }

    @Test func `join redeems a fresh offer instead of a stale pending response`() async throws {
        let issuerDir = try isolatedDir("iss-fresh")
        let joinerDir = try isolatedDir("join-fresh")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        _ = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let first = try issueLAN(dataDir: issuerDir, hostId: issuerId, offers: offers)
        let client = RedeemCountingClient { body in
            try PairingService.redeem(
                PairingService.RedeemInput(
                    dataDir: issuerDir,
                    issuerHostId: issuerId,
                    request: JSONDecoder().decode(PairingRedeemRequest.self, from: body),
                ),
                offers: offers,
            )
        }
        let receiptURL = PairingService.receiptURL(in: joinerDir)
        try FileManager.default.createDirectory(at: receiptURL, withIntermediateDirectories: true)
        await #expect(throws: PairingError.self) {
            try await PairingService.join(
                request: PairingJoinRequest(qrPayload: first.qrPayload),
                dataDir: joinerDir,
                hostId: joinerId,
                client: client,
            )
        }
        #expect(client.posts == 1)
        #expect(client.codes == [first.code])
        #expect(PairingService.loadPendingRedeem(dataDir: joinerDir) != nil)
        let second = try issueLAN(dataDir: issuerDir, hostId: issuerId, offers: offers)
        #expect(second.code != first.code)
        try FileManager.default.removeItem(at: receiptURL)
        let result = try await PairingService.join(
            request: PairingJoinRequest(qrPayload: second.qrPayload),
            dataDir: joinerDir,
            hostId: joinerId,
            client: client,
        )
        #expect(client.posts == 2)
        #expect(client.codes == [first.code, second.code])
        #expect(result.peerHostId == issuerId)
        #expect(try PairingService.loadReceipt(dataDir: joinerDir)?.peerHostId == issuerId)
        #expect(try PeerPinStore(dataDir: joinerDir).contains(fingerprint: issuer.deviceFingerprint))
        #expect(!FileManager.default.fileExists(atPath: PairingService.pendingRedeemURL(in: joinerDir).path))
    }

    @Test func `pendingMatches requires the same offer code`() {
        let response = PairingRedeemResponse(
            hostId: "host-a",
            deviceCertificatePEM: "dev",
            deviceFingerprint: "abcd",
            caCertificatePEM: "ca",
            caFingerprint: "ca-fp",
            issuedCertificatePEM: "iss",
            issuedFingerprint: "iss-fp",
            agentPort: 7_778,
        )
        let pending = PairingService.PendingRedeemRecord(
            codeHash: PairingCode.hash("ABCD-EFGH"),
            response: response,
        )
        let same = PairingPayload(
            code: "ABCD-EFGH",
            host: "192.168.0.9",
            port: 7_777,
            hostId: "host-a",
            fingerprint: "abcd",
        )
        let fresh = PairingPayload(
            code: "WXYZ-2345",
            host: "192.168.0.9",
            port: 7_777,
            hostId: "host-a",
            fingerprint: "abcd",
        )
        #expect(PairingService.pendingMatches(pending, expected: same))
        #expect(!PairingService.pendingMatches(pending, expected: fresh))
    }

    private func issueLAN(
        dataDir: URL,
        hostId: String,
        offers: PairingOfferStore,
    ) throws -> PairingIssueResponse {
        try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dataDir,
                hostId: hostId,
                advertisedHost: "192.168.0.22",
                advertisedHosts: ["192.168.0.22"],
            ),
            offers: offers,
        )
    }

    private func redeemRequest(
        code: String,
        joiner: HomeCertificateMaterial,
    ) throws -> PairingRedeemRequest {
        try PairingRedeemRequest(
            code: code,
            hostId: joiner.hostId,
            csrPEM: HomeCAService.makeDeviceCSR(hostId: joiner.hostId, keyPEM: joiner.deviceKeyPEM),
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
    }
}

private final class RedeemCountingClient: PairingHTTPClient, @unchecked Sendable {
    var posts = 0
    var codes: [String] = []
    let handler: @Sendable (Data) throws -> PairingRedeemResponse

    init(handler: @escaping @Sendable (Data) throws -> PairingRedeemResponse) {
        self.handler = handler
    }

    func get(url: URL) async throws -> PairingHTTPResponse {
        struct Probe: Encodable { var apiVersion: Int }
        return try PairingHTTPResponse(
            status: 200,
            body: JSONEncoder().encode(Probe(apiVersion: APIContract.version)),
        )
    }

    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        posts += 1
        let request = try JSONDecoder().decode(PairingRedeemRequest.self, from: body)
        codes.append(request.code)
        let response = try handler(body)
        return try PairingHTTPResponse(status: 200, body: JSONEncoder().encode(response))
    }
}
