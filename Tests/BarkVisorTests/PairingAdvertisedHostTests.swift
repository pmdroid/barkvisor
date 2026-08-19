import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Pairing advertised host (PAS-226)")
struct PairingAdvertisedHostTests {
    private func isolatedDir(_ label: String = "pair-adv") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(label)-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `issue persists advertised host so current offer matches after reload`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "box.home.example",
                advertisedHosts: ["192.168.0.8", "100.64.0.9"],
            ),
            offers: offers,
        )
        #expect(issued.advertisedHost == "box.home.example")
        #expect(issued.qrPayload.contains("host=box.home.example"))
        #expect(try offers.load()?.advertisedHost == "box.home.example")
        let current = try PairingService.currentOffer(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        #expect(current.advertisedHost == "box.home.example")
        #expect(current.qrPayload.contains("host=box.home.example"))
        #expect(current.code == issued.code)
    }

    @Test func `legacy pairing offer without advertisedHost still decodes`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        let issued = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        let stored = try #require(try offers.load())
        let legacyJSON = """
        {
          "codeHash": "\(stored.codeHash)",
          "codeDisplay": "\(issued.code)",
          "createdAt": "\(issued.expiresAt)",
          "expiresAt": "2099-01-01T00:00:00Z",
          "agentPort": 7778
        }
        """
        try Data(legacyJSON.utf8).write(to: offers.fileURL, options: [.atomic])
        let loaded = try #require(try offers.load())
        #expect(loaded.advertisedHost == nil)
        #expect(loaded.codeDisplay == issued.code)
        let current = try PairingService.currentOffer(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHosts: ["10.0.0.4"],
            ),
            offers: offers,
        )
        #expect(current.qrPayload.contains("host=10.0.0.4"))
    }

    @Test func `explicit advertised host is rejected without falling back`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let offers = PairingOfferStore(dataDir: dir)
        _ = try PairingService.issue(
            PairingService.IssueInput(
                dataDir: dir,
                hostId: hostId,
                advertisedHost: "192.168.0.8",
                advertisedHosts: ["192.168.0.8"],
            ),
            offers: offers,
        )
        #expect(try offers.load() != nil)
        let blocked = [
            "localhost",
            "foo.internal",
            "evil.example/path",
            "has space",
            "100.100.100.200",
        ]
        for host in blocked {
            #expect(throws: PairingError.self) {
                try PairingService.issue(
                    PairingService.IssueInput(
                        dataDir: dir,
                        hostId: hostId,
                        advertisedHost: host,
                        advertisedHosts: ["192.168.0.8"],
                    ),
                    offers: offers,
                )
            }
            #expect(try offers.load() == nil)
        }
    }
}
