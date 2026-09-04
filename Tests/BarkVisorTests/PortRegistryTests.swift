import Foundation
import GRDB
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
@testable import BarkVisorCore

final class PortRegistryTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL
    private let hostLinux: String
    private let fixtureCPUCount: Int

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp

        let dbPath = tmp.appendingPathComponent("test.sqlite").path
        let pool = try DatabasePool(path: dbPath)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
        hostLinux = GuestProfiles.defaultLinuxID(forImageArch: PlatformCapabilities.hostArch)
        fixtureCPUCount = min(2, max(1, PlatformHost.cpuCount))
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Claims

    @Test func `claims include implicit NAT VM port forwards`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.count == 1)
        #expect(claims[0].hostPort == 8_123)
        #expect(claims[0].proto == "tcp")
        #expect(claims[0].workloadKind == "vm")
        #expect(claims[0].workloadId == "vm-ha")
        #expect(claims[0].workloadName == "Home Assistant")
    }

    @Test func `claims skip isolated VM leftover forwards`() async throws {
        let isolated = try await NetworkService.create(
            CreateNetworkParams(
                name: "private", mode: "isolated", bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        try await insertVM(
            id: "vm-iso", name: "Isolated leftover",
            networkId: isolated.id,
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 80)],
        )
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.isEmpty)
    }

    @Test func `claims exclude the updating VM`() async throws {
        try await insertVM(
            id: "vm-self", name: "Self",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22)],
        )
        let claims = try await dbPool.read { db in
            try PortRegistry.claims(db: db, excludingVM: "vm-self")
        }
        #expect(claims.isEmpty)
    }

    // MARK: - assertAvailable

    @Test func `second VM same host port is port_in_use with occupant name`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        let error = await #expect(throws: BarkVisorError.self) {
            try await PortRegistry.assertAvailable(
                [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 80)],
                db: self.dbPool,
            )
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.httpStatus == 409)
        #expect(error?.errorDescription?.contains("Home Assistant") == true)
        #expect(error?.errorDescription?.contains("8123") == true)
    }

    @Test func `same host port different proto is allowed`() async throws {
        try await insertVM(
            id: "vm-dns", name: "DNS",
            portForwards: [PortForwardRule(protocol: "udp", hostPort: 53, guestPort: 53)],
        )
        try await PortRegistry.assertAvailable(
            [PortForwardRule(protocol: "tcp", hostPort: 53, guestPort: 53)],
            db: dbPool,
        )
    }

    @Test func `update excluding self keeps existing forwards`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        try await PortRegistry.assertAvailable(
            [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
            excludingVM: "vm-ha",
            db: dbPool,
        )
    }

    @Test func `duplicate host port in one request is port_in_use`() throws {
        let error = #expect(throws: BarkVisorError.self) {
            try PortRegistry.assertUnique([
                PortForwardRule(protocol: "tcp", hostPort: 8_080, guestPort: 80),
                PortForwardRule(protocol: "TCP", hostPort: 8_080, guestPort: 8_080),
            ])
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.httpStatus == 409)
        #expect(error?.errorDescription?.contains("more than once") == true)
    }

    // MARK: - Create / update wiring

    @Test func `create validation rejects occupant port`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        let error = await #expect(throws: BarkVisorError.self) {
            try await VMLifecycleService.validateCreateVMInputs(
                params: CreateVMParams(
                    name: "second",
                    vmType: self.hostLinux,
                    cpuCount: self.fixtureCPUCount,
                    memoryMB: 512,
                    isoId: "iso-1",
                    portForwards: [
                        PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 80),
                    ],
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.errorDescription?.contains("Home Assistant") == true)
    }

    @Test func `create validation allows unused host port`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        try await VMLifecycleService.validateCreateVMInputs(
            params: CreateVMParams(
                name: "second",
                vmType: hostLinux,
                cpuCount: fixtureCPUCount,
                memoryMB: 512,
                isoId: "iso-1",
                portForwards: [
                    PortForwardRule(protocol: "tcp", hostPort: 2_222, guestPort: 22),
                ],
            ),
            db: dbPool,
        )
    }

    @Test func `update VM rejects colliding port forwards`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        try await insertVM(id: "vm-other", name: "Other", portForwards: nil)
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVM(
                id: "vm-other",
                params: UpdateVMParams(
                    portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 80)],
                ),
                db: self.dbPool,
            )
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.errorDescription?.contains("Home Assistant") == true)
    }

    @Test func `update VM can keep its own port forwards`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        let updated = try await VMLifecycleService.updateVM(
            id: "vm-ha",
            params: UpdateVMParams(
                portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
                description: "still mine",
            ),
            db: dbPool,
        )
        #expect(updated.description == "still mine")
        #expect(updated.decodedPortForwards.first?.hostPort == 8_123)
    }

    @Test func `update VMSpec rejects colliding port forwards`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 8_123, guestPort: 8_123)],
        )
        try await insertVM(id: "vm-other", name: "Other", portForwards: nil)
        let other = try await dbPool.read { db in try VM.fetchOne(db, key: "vm-other") }
        let occupant = try #require(other)
        var spec = WorkloadSpecProjector.fromVM(occupant)
        spec.spec.guestType = hostLinux
        spec.spec.networks = [
            WorkloadNetwork(
                mode: "nat",
                portForwards: [WorkloadPortForward(hostPort: 8_123, guestPort: 80, proto: "tcp")],
            ),
        ]
        let error = await #expect(throws: BarkVisorError.self) {
            _ = try await VMLifecycleService.updateVMSpec(
                id: "vm-other", spec: spec, db: self.dbPool,
            )
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.errorDescription?.contains("Home Assistant") == true)
    }

    @Test func `spec validate rejects duplicate host ports`() {
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "dup"),
            spec: WorkloadSpecBody(
                resources: WorkloadResources(cpu: fixtureCPUCount, memoryMb: 512),
                guestType: hostLinux,
                networks: [
                    WorkloadNetwork(
                        mode: "nat",
                        portForwards: [
                            WorkloadPortForward(hostPort: 8_080, guestPort: 80, proto: "tcp"),
                            WorkloadPortForward(hostPort: 8_080, guestPort: 8_080, proto: "tcp"),
                        ],
                    ),
                ],
            ),
        )
        let error = #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.validate(spec)
        }
        #expect(error?.code == "port_in_use")
    }

    // MARK: - nextFree (PAS-228)

    @Test func `nextFree uses preferred when unclaimed`() async throws {
        let port = try await PortRegistry.nextFree(preferred: 18_080, proto: "tcp", db: dbPool)
        #expect(port >= 18_080)
        #expect(PortRegistry.probeListen(port: port, proto: "tcp"))
    }

    @Test func `nextFree skips a claimed NAT host port`() async throws {
        try await insertVM(
            id: "vm-ha", name: "Home Assistant",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 18_123, guestPort: 8_123)],
        )
        let port = try await PortRegistry.nextFree(preferred: 18_123, proto: "tcp", db: dbPool)
        #expect(port > 18_123)
        #expect(PortRegistry.probeListen(port: port, proto: "tcp"))
    }

    @Test func `nextFree ignores isolated leftover forwards`() async throws {
        let isolated = try await NetworkService.create(
            CreateNetworkParams(
                name: "private-next", mode: "isolated", bridge: nil, macAddress: nil, dnsServer: nil,
            ),
            db: dbPool,
        )
        try await insertVM(
            id: "vm-iso-next", name: "Isolated leftover",
            networkId: isolated.id,
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 80)],
        )
        let port = try await PortRegistry.nextFree(preferred: 18_080, proto: "tcp", db: dbPool)
        #expect(port >= 18_080)
        let claims = try await dbPool.read { db in try PortRegistry.claims(db: db) }
        #expect(claims.isEmpty)
    }

    @Test func `nextFree extraOccupied skips this VM host port`() async throws {
        let port = try await PortRegistry.nextFree(
            preferred: 18_222,
            proto: "tcp",
            extraOccupied: [18_222],
            db: dbPool,
        )
        #expect(port > 18_222)
    }

    @Test func `nextFree excludingVM can reuse that VM host port`() async throws {
        try await insertVM(
            id: "vm-self-next", name: "Self",
            portForwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 80)],
        )
        let port = try await PortRegistry.nextFree(
            preferred: 18_080,
            proto: "tcp",
            excludingVM: "vm-self-next",
            db: dbPool,
        )
        #expect(port >= 18_080)
        let others = try await dbPool.read { db in
            try PortRegistry.claims(db: db, excludingVM: "vm-self-next")
        }
        #expect(others.isEmpty)
    }

    // MARK: - Bind probe

    @Test func `probeListen is false while a TCP socket is bound`() {
        #if os(Linux)
            let sockType = Int32(SOCK_STREAM.rawValue)
        #else
            let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        #expect(nameResult == 0)
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(port > 0)
        #expect(PortRegistry.probeListen(port: port, proto: "tcp") == false)
        #expect(PortRegistry.probeListen(port: port, proto: "udp") == true)
    }

    @Test func `probeListen is false while a UDP socket is bound`() {
        #if os(Linux)
            let sockType = Int32(SOCK_DGRAM.rawValue)
        #else
            let sockType = SOCK_DGRAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        #expect(nameResult == 0)
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(port > 0)
        #expect(PortRegistry.probeListen(port: port, proto: "udp") == false)
        #expect(PortRegistry.probeListen(port: port, proto: "tcp") == true)
    }

    @Test func `probeListen is false while loopback TCP is bound`() {
        #if os(Linux)
            let sockType = Int32(SOCK_STREAM.rawValue)
        #else
            let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        #expect(nameResult == 0)
        let port = Int(UInt16(bigEndian: bound.sin_port))
        #expect(port > 0)
        #expect(PortRegistry.probeListen(port: port, proto: "tcp") == false)
    }

    @Test func `nextFree skips a loopback-bound TCP port`() async throws {
        #if os(Linux)
            let sockType = Int32(SOCK_STREAM.rawValue)
        #else
            let sockType = SOCK_STREAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        #expect(fd >= 0)
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindResult == 0)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        #expect(nameResult == 0)
        let occupied = Int(UInt16(bigEndian: bound.sin_port))
        #expect(occupied > 0)
        let port = try await PortRegistry.nextFree(preferred: occupied, proto: "tcp", db: dbPool)
        #expect(port > occupied)
    }

    // MARK: - Helpers

    private func insertVM(
        id: String,
        name: String,
        networkId: String? = nil,
        portForwards: [PortForwardRule]?,
    ) async throws {
        let diskPath = tmpDir.appendingPathComponent("\(id).qcow2").path
        let vmType = hostLinux
        let cpuCount = fixtureCPUCount
        try await dbPool.write { db in
            let disk = Disk(
                id: "disk-\(id)",
                name: "boot",
                path: diskPath,
                sizeBytes: 1_000_000,
                format: "qcow2",
                vmId: id,
                autoCreated: false,
                status: "ready",
                createdAt: "2026-01-01T00:00:00Z",
            )
            try disk.insert(db)
            let vm = VM(
                id: id,
                name: name,
                vmType: vmType,
                state: "stopped",
                cpuCount: cpuCount,
                memoryMb: 512,
                bootDiskId: disk.id,
                networkId: networkId,
                cloudInitPath: nil,
                description: nil,
                bootOrder: "cd",
                displayResolution: "1280x800",
                additionalDiskIds: nil,
                uefi: true,
                tpmEnabled: false,
                macAddress: nil,
                sharedPaths: nil,
                portForwards: JSONColumnCoding.encode(portForwards),
                autoCreated: false,
                pendingChanges: false,
                createdAt: "2026-01-01T00:00:00Z",
                updatedAt: "2026-01-01T00:00:00Z",
            )
            try vm.insert(db)
        }
    }
}
