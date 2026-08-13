#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import Testing
@testable import BarkVisorCore

@Suite("HealthProbeService")
struct HealthProbeServiceTests {
    private func makeVM(
        state: String = "running",
        health: WorkloadHealthSpec? = nil,
        forwards: [PortForwardRule] = [],
    ) -> VM {
        var vm = VM(
            id: "vm-1",
            name: "probe",
            vmType: "linux-arm64",
            state: state,
            cpuCount: min(2, max(1, PlatformHost.cpuCount)),
            memoryMb: 512,
            bootDiskId: "disk-1",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: nil,
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-08-13T12:00:00Z",
            updatedAt: "2026-08-13T12:00:00Z",
        )
        vm.setPortForwards(forwards.isEmpty ? nil : forwards)
        vm.setHealth(health)
        return vm
    }

    @Test func `no check is unobserved`() async {
        let service = HealthProbeService(transport: .live)
        let results = await service.probeNow(vm: makeVM())
        #expect(results == .unobserved)
        #expect(!results.configured)
    }

    @Test func `hostfwd is preferred over guest ip`() {
        let vm = makeVM(forwards: [
            PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080),
        ])
        let target = HealthProbeTarget.resolve(
            port: 8_080, vm: vm, guestIPs: ["192.168.1.20", HealthProbeTarget.slirpGuestIPv4],
        )
        #expect(target?.host == "127.0.0.1")
        #expect(target?.port == 18_080)
        #expect(target?.via == "hostfwd")
    }

    @Test func `slirp guest ip is not a probe target`() {
        let vm = makeVM()
        let target = HealthProbeTarget.resolve(
            port: 8_080, vm: vm, guestIPs: [HealthProbeTarget.slirpGuestIPv4, "127.0.0.1"],
        )
        #expect(target == nil)
    }

    @Test func `bridged guest ip is used without hostfwd`() {
        let vm = makeVM()
        let target = HealthProbeTarget.resolve(port: 5_432, vm: vm, guestIPs: ["192.168.64.10"])
        #expect(target?.host == "192.168.64.10")
        #expect(target?.port == 5_432)
        #expect(target?.via == "guest")
    }

    @Test func `http threshold promotes after consecutive passes`() async {
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in true },
            tcp: { _, _, _ in false },
        )
        let service = HealthProbeService(transport: transport)
        let vm = makeVM(
            health: WorkloadHealthSpec(
                intervalSec: 5,
                healthyThreshold: 2,
                unhealthyThreshold: 3,
                http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
            ),
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080)],
        )
        let t0 = Date()
        _ = await service.probeNow(vm: vm, now: t0)
        let first = await service.results(for: vm)
        #expect(first.httpConfigured)
        #expect(first.http == nil)

        _ = await service.probeNow(vm: vm, now: t0.addingTimeInterval(10))
        let second = await service.results(for: vm)
        #expect(second.http == true)
        #expect(second.passed)
    }

    @Test func `http failures degrade after unhealthy threshold`() async {
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in false },
            tcp: { _, _, _ in true },
        )
        let service = HealthProbeService(transport: transport)
        let vm = makeVM(
            health: WorkloadHealthSpec(
                intervalSec: 5,
                healthyThreshold: 1,
                unhealthyThreshold: 2,
                http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
            ),
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080)],
        )
        let t0 = Date()
        _ = await service.probeNow(vm: vm, now: t0)
        #expect(await service.results(for: vm).http == nil)
        _ = await service.probeNow(vm: vm, now: t0.addingTimeInterval(10))
        let failed = await service.results(for: vm)
        #expect(failed.http == false)
        #expect(failed.failed)
    }

    @Test func `live tcp probe against localhost`() async throws {
        let listener = try LocalTCPListener()
        defer { listener.stop() }
        let transport = HealthProbeTransport.live
        let ok = await transport.tcp("127.0.0.1", listener.port, 1)
        #expect(ok)
        let closed = await transport.tcp("127.0.0.1", 1, 0.2)
        #expect(!closed)
    }

    @Test func `exec check is rejected on vms`() {
        let spec = WorkloadHealthSpec(exec: WorkloadHealthExecCheck(command: ["pg_isready"]))
        #expect(throws: BarkVisorError.self) {
            try WorkloadHealthSpec.validate(spec)
        }
    }

    @Test func `http path must be a path not a url`() throws {
        #expect(throws: BarkVisorError.self) {
            try WorkloadHealthHTTPCheck(path: "http://evil.test/health", port: 80).validate()
        }
        try WorkloadHealthHTTPCheck(path: "/health", port: 8_080).validate()
    }
}

/// Minimal IPv4 TCP listener for live probe tests (macOS + Linux).
private final class LocalTCPListener: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init() throws {
        let sock = socket(AF_INET, PlatformSocket.stream, 0)
        guard sock >= 0 else { throw BarkVisorError.badRequest("socket") }
        var yes: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRC == 0, listen(sock, 1) == 0 else {
            close(sock)
            throw BarkVisorError.badRequest("bind")
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameRC = withUnsafeMutablePointer(to: &got) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(sock, $0, &len)
            }
        }
        guard nameRC == 0 else {
            close(sock)
            throw BarkVisorError.badRequest("getsockname")
        }
        self.fd = sock
        self.port = Int(UInt16(bigEndian: got.sin_port))
    }

    func stop() {
        close(fd)
    }
}
