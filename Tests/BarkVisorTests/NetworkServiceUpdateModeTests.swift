import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

/// `NetworkService.update` versus the Workloads already attached to the
/// network (#634). A mode change must not persist a network/Workload pair that
/// can no longer launch, or silently drop a running Workload's port claim.
final class NetworkServiceUpdateModeTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Update mode vs attached Workloads (#634)

    private func seedNetwork(_ id: String, mode: String) async throws {
        try await dbPool.write { db in
            try Network(
                id: id, name: id, mode: mode, bridge: nil,
                macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
            ).insert(db)
        }
    }

    /// Attach a Workload the way a create would leave it: its own port-forward
    /// rules, and the same rows `PortRegistry.claims` reads back.
    private func attachWorkload(
        networkID: String,
        id: String,
        name: String,
        state: String = "stopped",
        forwards: [PortForwardRule] = [],
    ) async throws {
        try await dbPool.write { db in
            var vm = VM(
                id: id, name: name, vmType: "linux-arm64", state: state,
                cpuCount: 2, memoryMb: 1_024, bootDiskId: nil,
                networkId: networkID, cloudInitPath: nil,
                description: nil, bootOrder: "cd", displayResolution: "1280x800",
                additionalDiskIds: nil, uefi: true, tpmEnabled: false,
                macAddress: nil, sharedPaths: nil, portForwards: nil,
                autoCreated: false, pendingChanges: false,
                createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
            )
            vm.setPortForwards(forwards.isEmpty ? nil : forwards)
            try vm.insert(db)
        }
    }

    private func claims() async throws -> [PortClaim] {
        try await dbPool.read { db in try PortRegistry.claims(db: db) }
    }

    @Test func `update NAT to isolated is rejected while an attached Workload forwards ports`() async throws {
        try await seedNetwork("net-mode-1", mode: "nat")
        try await attachWorkload(
            networkID: "net-mode-1", id: "vm-mode-1", name: "web",
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 8_080, guestPort: 80)],
        )

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: "net-mode-1", name: nil, mode: "isolated",
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 409)
        // The message names the Workload so the person knows what to detach.
        #expect(error?.errorDescription?.contains("web") == true)

        // Nothing moved: the network keeps its mode, the Workload keeps its
        // forwards, and the claim is still counted.
        let network = try await dbPool.read { db in try Network.fetchOne(db, key: "net-mode-1") }
        #expect(network?.mode == "nat")
        let vm = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-mode-1") }
        #expect(vm?.decodedPortForwards.count == 1)
        #expect(try await claims().contains { $0.hostPort == 8_080 && $0.workloadId == "vm-mode-1" })
    }

    @Test func `update NAT to isolated is rejected for a running Workload holding its claim`() async throws {
        try await seedNetwork("net-mode-2", mode: "nat")
        try await attachWorkload(
            networkID: "net-mode-2", id: "vm-mode-2", name: "api", state: "running",
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 9_001, guestPort: 80)],
        )

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: "net-mode-2", name: nil, mode: "isolated",
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 409)

        let vm = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-mode-2") }
        #expect(vm?.state == "running")
        #expect(vm?.decodedPortForwards.count == 1)
        let network = try await dbPool.read { db in try Network.fetchOne(db, key: "net-mode-2") }
        #expect(network?.mode == "nat")
        #expect(try await claims().contains { $0.hostPort == 9_001 && $0.workloadId == "vm-mode-2" })
    }

    @Test func `update names every attached Workload that would be stranded`() async throws {
        let rules = [PortForwardRule(protocol: "tcp", hostPort: 9_100, guestPort: 80)]
        try await seedNetwork("net-mode-3", mode: "nat")
        try await attachWorkload(
            networkID: "net-mode-3", id: "vm-mode-3a", name: "web", forwards: rules,
        )
        try await attachWorkload(
            networkID: "net-mode-3", id: "vm-mode-3b", name: "api", forwards: rules,
        )
        // Attached but forwarding nothing — not stranded, so not named.
        try await attachWorkload(networkID: "net-mode-3", id: "vm-mode-3c", name: "quiet")

        let error = await #expect(throws: BarkVisorError.self) {
            try await NetworkService.update(
                UpdateNetworkParams(
                    id: "net-mode-3", name: nil, mode: "isolated",
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.httpStatus == 409)
        let message = error?.errorDescription ?? ""
        #expect(message.contains("2 attached Workload(s)"))
        #expect(message.contains("\"api\""))
        #expect(message.contains("\"web\""))
        #expect(!message.contains("\"quiet\""))
    }

    @Test func `update isolated to NAT keeps a stranded Workload launchable`() async throws {
        // Legacy shape: forwards on a non-NAT network. Moving back to NAT is a
        // widening, so it must not be blocked.
        try await seedNetwork("net-mode-4", mode: "isolated")
        try await attachWorkload(
            networkID: "net-mode-4", id: "vm-mode-4", name: "web",
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 9_200, guestPort: 80)],
        )

        let updated = try await NetworkService.update(
            UpdateNetworkParams(
                id: "net-mode-4", name: nil, mode: "nat",
                bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        #expect(updated.mode == "nat")
        #expect(try await claims().contains { $0.hostPort == 9_200 && $0.workloadId == "vm-mode-4" })
    }

    @Test func `update mode change succeeds when no Workload is attached`() async throws {
        try await seedNetwork("net-mode-5", mode: "nat")
        let updated = try await NetworkService.update(
            UpdateNetworkParams(
                id: "net-mode-5", name: nil, mode: "isolated",
                bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        #expect(updated.mode == "isolated")
    }

    @Test func `update mode change succeeds when attached Workloads have no port forwards`() async throws {
        try await seedNetwork("net-mode-6", mode: "nat")
        try await attachWorkload(networkID: "net-mode-6", id: "vm-mode-6", name: "quiet")
        let updated = try await NetworkService.update(
            UpdateNetworkParams(
                id: "net-mode-6", name: nil, mode: "isolated",
                bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        #expect(updated.mode == "isolated")
        #expect(updated.bridge == nil)
    }

    @Test func `update metadata only still succeeds on a network with a forwarding Workload`() async throws {
        try await seedNetwork("net-mode-7", mode: "nat")
        try await attachWorkload(
            networkID: "net-mode-7", id: "vm-mode-7", name: "web",
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 9_300, guestPort: 80)],
        )

        let updated = try await NetworkService.update(
            UpdateNetworkParams(
                id: "net-mode-7", name: "renamed", mode: nil,
                bridge: nil, macAddress: "52:54:00:ab:cd:ef", dnsServer: nil,
            ),
            db: dbPool,
        )
        #expect(updated.name == "renamed")
        #expect(updated.mode == "nat")
        #expect(updated.macAddress == "52:54:00:ab:cd:ef")
        #expect(try await claims().contains { $0.hostPort == 9_300 && $0.workloadId == "vm-mode-7" })
    }

    /// Attach a forwarding Workload the way the create seam does: the network
    /// fetch, the mode guard, and the insert in one write transaction. Returns
    /// whether the attach persisted.
    private static func attachForwardingWorkload(
        pool: DatabasePool,
        networkID: String,
        id: String,
        hostPort: Int,
    ) async -> Bool {
        do {
            try await pool.write { db in
                guard let network = try Network.fetchOne(db, key: networkID) else {
                    throw BarkVisorError.notFound()
                }
                try NetworkCapability.requirePortForwardsAllowed(count: 1, network: network)
                var vm = VM(
                    id: id, name: "racer", vmType: "linux-arm64", state: "stopped",
                    cpuCount: 2, memoryMb: 1_024, bootDiskId: nil,
                    networkId: networkID, cloudInitPath: nil,
                    description: nil, bootOrder: "cd", displayResolution: "1280x800",
                    additionalDiskIds: nil, uefi: true, tpmEnabled: false,
                    macAddress: nil, sharedPaths: nil, portForwards: nil,
                    autoCreated: false, pendingChanges: false,
                    createdAt: "2025-01-01T00:00:00Z", updatedAt: "2025-01-01T00:00:00Z",
                )
                vm.setPortForwards([PortForwardRule(protocol: "tcp", hostPort: hostPort, guestPort: 80)])
                try vm.insert(db)
            }
            return true
        } catch {
            return false
        }
    }

    /// Flip a network to isolated. Returns whether the mode change persisted.
    private static func flipToIsolated(pool: DatabasePool, _ id: String) async -> Bool {
        do {
            _ = try await NetworkService.update(
                UpdateNetworkParams(
                    id: id, name: nil, mode: "isolated",
                    bridge: nil, macAddress: nil, dnsServer: nil,
                ),
                db: pool,
            )
            return true
        } catch {
            return false
        }
    }

    @Test func `concurrent attach versus mode change resolves to one winner`() async throws {
        // Both writers serialize on the same pool, so the pair is either
        // "isolated with nothing attached" or "NAT with the Workload attached"
        // — never a half-applied state.
        let pool = dbPool
        for attempt in 0 ..< 20 {
            let networkID = "net-race-\(attempt)"
            let vmID = "vm-race-\(attempt)"
            try await seedNetwork(networkID, mode: "nat")

            async let attachedOK = Self.attachForwardingWorkload(
                pool: pool, networkID: networkID, id: vmID, hostPort: 9_400,
            )
            async let flippedOK = Self.flipToIsolated(pool: pool, networkID)
            let attach = await attachedOK
            let flip = await flippedOK

            let network = try await dbPool.read { db in try Network.fetchOne(db, key: networkID) }
            let vm = try await dbPool.read { db in try VM.fetchOne(db, key: vmID) }
            if flip {
                // The mode change won, so the attach must have been rejected.
                #expect(attach == false)
                #expect(network?.mode == "isolated")
                #expect(vm == nil)
            } else {
                // The attach won, so the mode change must have been rejected.
                #expect(attach)
                #expect(network?.mode == "nat")
                #expect(vm?.decodedPortForwards.count == 1)
            }
        }
    }
}
