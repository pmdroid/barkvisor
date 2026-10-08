import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct GuestDNSValidationTests {
    @Test(arguments: ["8.8.8.8", "10.0.2.2", "10.0.2.15", "192.0.2.3"])
    func `isolated create rejects unlaunchable DNS`(_ dns: String) async throws {
        let (pool, dir) = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(
                    name: "invalid", mode: "isolated", bridge: nil,
                    macAddress: nil, dnsServer: dns,
                ),
                db: pool,
            )
        }
        #expect(try await pool.read { try Network.fetchCount($0) } == 0)
    }

    @Test(arguments: ["10.0.2.2", "10.0.2.15"])
    func `nat create rejects reserved DNS`(_ dns: String) async throws {
        let (pool, dir) = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        await #expect(throws: BarkVisorError.self) {
            try await NetworkService.create(
                CreateNetworkParams(
                    name: "invalid", mode: "nat", bridge: nil,
                    macAddress: nil, dnsServer: dns,
                ),
                db: pool,
            )
        }
        #expect(try await pool.read { try Network.fetchCount($0) } == 0)
    }

    @Test func `mode change revalidates existing DNS before persistence`() async throws {
        let (pool, dir) = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nat = try await NetworkService.create(
            CreateNetworkParams(
                name: "external-dns", mode: "nat", bridge: nil,
                macAddress: nil, dnsServer: "8.8.8.8",
            ),
            db: pool,
        )
        await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: nat.id, name: nil, mode: "isolated", bridge: nil,
                    macAddress: nil, dnsServer: nil,
                ),
                db: pool,
            )
        }
        let stored = try await pool.read { try Network.fetchOne($0, key: nat.id) }
        #expect(stored?.mode == "nat")
        #expect(stored?.dnsServer == "8.8.8.8")
        let isolated = try await NetworkService.update(
            UpdateNetworkParams(
                id: nat.id, name: nil, mode: "isolated", bridge: nil,
                macAddress: nil, dnsServer: "10.0.2.3",
            ),
            db: pool,
        )
        #expect(isolated.mode == "isolated")
        #expect(isolated.dnsServer == "10.0.2.3")
    }

    @Test(arguments: ["8.8.8.8", "10.0.2.2", "10.0.2.15"])
    func `isolated update retains previous valid value on rejection`(_ dns: String) async throws {
        let (pool, dir) = try database()
        defer { try? FileManager.default.removeItem(at: dir) }
        let isolated = try await NetworkService.create(
            CreateNetworkParams(
                name: "private", mode: "isolated", bridge: nil,
                macAddress: nil, dnsServer: "10.0.2.3",
            ),
            db: pool,
        )
        await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: isolated.id, name: nil, mode: nil, bridge: nil,
                    macAddress: nil, dnsServer: dns,
                ),
                db: pool,
            )
        }
        let stored = try await pool.read { try Network.fetchOne($0, key: isolated.id) }
        #expect(stored?.dnsServer == "10.0.2.3")
    }

    @Test(arguments: ["8.8.8.8", "10.0.2.2", "10.0.2.15"])
    func `legacy invalid isolated DNS is rejected at launch`(_ dns: String) {
        #expect(throws: BarkVisorError.self) {
            _ = try NetworkIntentResolver.resolve(
                NetworkIntent(publications: [], guestDNS: dns), runtime: .qemu, mode: .isolated,
            )
        }
    }

    @Test func `accepted DNS still builds launch arguments`() throws {
        for mode in [NetworkMode.nat, .isolated] {
            let plan = try NetworkIntentResolver.resolve(
                NetworkIntent(publications: [], guestDNS: "10.0.2.3"), runtime: .qemu, mode: mode,
            )
            #expect(plan.guestDNS == "10.0.2.3")
        }
        let nat = try NetworkIntentResolver.resolve(
            NetworkIntent(publications: [], guestDNS: "8.8.8.8"), runtime: .qemu, mode: .nat,
        )
        #expect(nat.guestDNS == "8.8.8.8")
    }

    private func database() throws -> (DatabasePool, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pool = try DatabasePool(path: dir.appendingPathComponent("db.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        return (pool, dir)
    }
}
