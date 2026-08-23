import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Pairing identity grant replay (PAS-283)")
struct PairingIdentityGrantReplayTests {
    private func isolatedDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `consumed replay grant stays bound to original offer expiry`() throws {
        let issuerDir = try isolatedDir("iss-replay-grant")
        let joinerDir = try isolatedDir("join-replay-grant")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let now = Date()
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                ttl: 45,
                now: now,
            ),
            offers: offers,
        )
        let csrPEM = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let request = PairingRedeemRequest(
            code: issued.code,
            hostId: joinerId,
            csrPEM: csrPEM,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: request,
                now: now,
            ),
            offers: offers,
        )
        let firstGrant = try PairingService.loadIdentityGrant(dataDir: issuerDir)
        let first = try #require(firstGrant)
        #expect(first.expiresAt == issued.expiresAt)
        let replayed = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: request,
                now: now.addingTimeInterval(1),
            ),
            offers: offers,
        )
        let againGrant = try PairingService.loadIdentityGrant(dataDir: issuerDir)
        let again = try #require(againGrant)
        #expect(again.expiresAt == issued.expiresAt)
        #expect(again.hostId == joinerId)
        try PairingService.authorizeIdentityRead(
            dataDir: issuerDir,
            hostId: joinerId,
            fingerprint: replayed.issuedFingerprint,
            now: now.addingTimeInterval(44),
        )
        #expect(throws: PairingError.identityNotGranted) {
            try PairingService.authorizeIdentityRead(
                dataDir: issuerDir,
                hostId: joinerId,
                fingerprint: replayed.issuedFingerprint,
                now: now.addingTimeInterval(46),
            )
        }
    }

    @Test func `consumed replay does not rearm grant after a later issue`() throws {
        let issuerDir = try isolatedDir("iss-replay-rearm")
        let joinerDir = try isolatedDir("join-replay-rearm")
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        _ = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let offers = PairingOfferStore(dataDir: issuerDir)
        let now = Date()
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: issuerDir,
                hostId: issuerId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
                ttl: 30,
                now: now,
            ),
            offers: offers,
        )
        let csrPEM = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let request = PairingRedeemRequest(
            code: issued.code,
            hostId: joinerId,
            csrPEM: csrPEM,
            deviceCertificatePEM: joiner.deviceCertificatePEM,
            caCertificatePEM: joiner.caCertificatePEM,
        )
        let remote = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: request,
                now: now,
            ),
            offers: offers,
        )
        try PairingService.authorizeIdentityRead(
            dataDir: issuerDir,
            hostId: joinerId,
            fingerprint: remote.issuedFingerprint,
        )
        offers.afterLoad = {
            offers.afterLoad = nil
            _ = try PairingService.issue(
                PairingService.IssueInput(
                    dataDir: issuerDir,
                    hostId: issuerId,
                    advertisedHost: "192.168.0.8",
                    advertisedHosts: ["192.168.0.8"],
                    ttl: 600,
                    now: now,
                ),
                offers: offers,
            )
        }
        defer { offers.afterLoad = nil }
        _ = try PairingService.redeem(
            PairingService.RedeemInput(
                dataDir: issuerDir,
                issuerHostId: issuerId,
                request: request,
                now: now.addingTimeInterval(1),
            ),
            offers: offers,
        )
        #expect(try PairingService.loadIdentityGrant(dataDir: issuerDir) == nil)
        #expect(throws: PairingError.identityNotGranted) {
            try PairingService.authorizeIdentityRead(
                dataDir: issuerDir,
                hostId: joinerId,
                fingerprint: remote.issuedFingerprint,
                now: now.addingTimeInterval(1),
            )
        }
    }
}
