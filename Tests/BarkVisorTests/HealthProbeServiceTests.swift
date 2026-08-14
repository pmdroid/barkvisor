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
        let target = HealthProbeTarget.resolve(
            port: 5_432, vm: vm, guestIPs: ["192.168.64.10"],
            policy: .allowPrivateGuestIPs,
        )
        #expect(target?.host == "192.168.64.10")
        #expect(target?.port == 5_432)
        #expect(target?.via == "guest")
    }

    @Test func `guest ip is ignored unless policy allows it`() {
        let vm = makeVM()
        #expect(
            HealthProbeTarget.resolve(port: 5_432, vm: vm, guestIPs: ["192.168.64.10"]) == nil,
        )
        #expect(
            HealthProbeTarget.resolve(
                port: 5_432, vm: vm, guestIPs: ["192.168.64.10"], policy: .hostfwdOnly,
            ) == nil,
        )
    }

    @Test func `public and link local guest ips are not probe targets`() {
        let vm = makeVM()
        for ip in ["8.8.8.8", "1.1.1.1", "169.254.169.254", "0.0.0.0", "224.0.0.1"] {
            #expect(
                HealthProbeTarget.resolve(
                    port: 80, vm: vm, guestIPs: [ip], policy: .allowPrivateGuestIPs,
                ) == nil,
                "rejected \(ip)",
            )
        }
    }

    @Test func `guest ipv4 must match on-link prefix when set`() {
        let vm = makeVM()
        let prefix = IPv4Prefix(network: 0xC0A8_4000, mask: 0xFFFF_FF00) // 192.168.64.0/24
        let policy = HealthProbePolicy(allowGuestReportedIPs: true, guestIPv4Prefixes: [prefix])
        let onLink = HealthProbeTarget.resolve(
            port: 80, vm: vm, guestIPs: ["192.168.64.10"], policy: policy,
        )
        #expect(onLink?.host == "192.168.64.10")
        #expect(
            HealthProbeTarget.resolve(
                port: 80, vm: vm, guestIPs: ["10.0.0.1"], policy: policy,
            ) == nil,
        )
    }

    @Test func `nat network policy is hostfwd only`() {
        let nat = Network(
            id: "net-nat", name: "nat", mode: "nat", bridge: nil,
            macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
        )
        #expect(HealthProbeTarget.policy(for: nat) == .hostfwdOnly)
        #expect(HealthProbeTarget.policy(for: nil) == .hostfwdOnly)
        let isolated = Network(
            id: "net-iso", name: "iso", mode: "isolated", bridge: nil,
            macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
        )
        #expect(HealthProbeTarget.policy(for: isolated) == .hostfwdOnly)
    }

    @Test func `bridged network policy allows guest ips`() {
        let bridged = Network(
            id: "net-br", name: "home", mode: "bridged", bridge: "bridge100",
            macAddress: nil, dnsServer: nil, autoCreated: false, isDefault: false,
        )
        let policy = HealthProbeTarget.policy(for: bridged)
        #expect(policy.allowGuestReportedIPs)
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

    @Test func `unresolvable target clears stale pass`() async {
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in true },
            tcp: { _, _, _ in true },
        )
        let service = HealthProbeService(transport: transport)
        let spec = WorkloadHealthSpec(
            intervalSec: 5,
            healthyThreshold: 1,
            http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
        )
        let forwarded = makeVM(
            health: spec,
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080)],
        )
        _ = await service.probeNow(vm: forwarded)
        #expect(await service.results(for: forwarded).http == true)
        #expect(await service.results(for: forwarded).passed)

        let lostIP = makeVM(health: spec)
        let after = await service.probeNow(vm: lostIP)
        #expect(after.http == nil)
        #expect(after.httpUnreachable)
        #expect(!after.passed)
    }

    @Test func `both probes must be observed to pass`() async {
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in true },
            tcp: { _, _, _ in true },
        )
        let service = HealthProbeService(transport: transport)
        let vm = makeVM(
            health: WorkloadHealthSpec(
                intervalSec: 5,
                healthyThreshold: 1,
                http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
                tcp: WorkloadHealthTCPCheck(port: 22),
            ),
            forwards: [PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080)],
        )
        let results = await service.probeNow(vm: vm)
        #expect(results.http == true)
        #expect(results.tcp == nil)
        #expect(results.tcpUnreachable)
        #expect(!results.passed)
    }

    @Test func `both configured probes passing is passed`() async {
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in true },
            tcp: { _, _, _ in true },
        )
        let service = HealthProbeService(transport: transport)
        let vm = makeVM(
            health: WorkloadHealthSpec(
                intervalSec: 5,
                healthyThreshold: 1,
                http: WorkloadHealthHTTPCheck(path: "/health", port: 8_080),
                tcp: WorkloadHealthTCPCheck(port: 22),
            ),
            forwards: [
                PortForwardRule(protocol: "tcp", hostPort: 18_080, guestPort: 8_080),
                PortForwardRule(protocol: "tcp", hostPort: 22_022, guestPort: 22),
            ],
        )
        let results = await service.probeNow(vm: vm)
        #expect(results.http == true)
        #expect(results.tcp == true)
        #expect(results.passed)
    }

    @Test func `ipv6 guest ip is a probe target`() {
        let vm = makeVM()
        let target = HealthProbeTarget.resolve(
            port: 5_432, vm: vm, guestIPs: ["fd12:3456:789a::10"],
            policy: .allowPrivateGuestIPs,
        )
        #expect(target?.host == "fd12:3456:789a::10")
        #expect(target?.port == 5_432)
        #expect(target?.via == "guest")
    }

    @Test func `ipv6 loopback is not a probe target`() {
        let vm = makeVM()
        #expect(HealthProbeTarget.resolve(
            port: 80, vm: vm, guestIPs: ["::1"], policy: .allowPrivateGuestIPs,
        ) == nil)
        #expect(HealthProbeTarget.resolve(
            port: 80, vm: vm, guestIPs: ["fe80::1"], policy: .allowPrivateGuestIPs,
        ) == nil)
        #expect(HealthProbeTarget.resolve(
            port: 80, vm: vm, guestIPs: ["2001:db8::1"], policy: .allowPrivateGuestIPs,
        ) == nil)
    }

    @Test func `serialized probes accumulate consecutive passes`() async {
        let gate = ProbeOverlapGate()
        let transport = HealthProbeTransport(
            http: { _, _, _, _, _ in await gate.nextHTTP() },
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
        async let first = service.probeNow(vm: vm, now: t0)
        await gate.waitUntilFirstParked()
        async let second = service.probeNow(vm: vm, now: t0.addingTimeInterval(10))
        await gate.releaseFirst()
        _ = await first
        _ = await second
        let results = await service.results(for: vm)
        #expect(results.http == true)
        #expect(results.passed)
    }

    @Test func `http probe does not follow redirects`() async throws {
        let internalServer = try LocalHTTPServer { _ in
            (200, [:], "internal")
        }
        defer { internalServer.stop() }
        let guestServer = try LocalHTTPServer { _ in
            (
                302,
                ["Location": "http://127.0.0.1:\(internalServer.port)/secret"],
                "",
            )
        }
        defer { guestServer.stop() }

        let ok = await HealthProbeLive.http(
            host: "127.0.0.1",
            port: guestServer.port,
            path: "/health",
            timeout: 2,
            expectedStatus: 200,
        )
        #expect(!ok)
        #expect(internalServer.hitCount() == 0)
        #expect(guestServer.hitCount() == 1)

        let redirectedStatus = await HealthProbeLive.http(
            host: "127.0.0.1",
            port: guestServer.port,
            path: "/health",
            timeout: 2,
            expectedStatus: nil,
        )
        // 302 is the terminal response (200...399) and must not hit Location.
        #expect(redirectedStatus)
        #expect(internalServer.hitCount() == 0)
    }
}

/// Coordinates two overlapping `probeNow` calls so the first stays in transport.
private actor ProbeOverlapGate {
    private var count = 0
    private var parked: CheckedContinuation<Void, Never>?
    private var firstSeen: CheckedContinuation<Void, Never>?

    func nextHTTP() async -> Bool {
        count += 1
        if count == 1 {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                parked = cont
                firstSeen?.resume()
                firstSeen = nil
            }
        }
        return true
    }

    func waitUntilFirstParked() async {
        if parked != nil { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if parked != nil {
                cont.resume()
            } else {
                firstSeen = cont
            }
        }
    }

    func releaseFirst() {
        parked?.resume()
        parked = nil
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

/// Tiny HTTP/1.1 responder for redirect / SSRF tests.
private final class LocalHTTPServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var hits = 0
    private var running = true
    private let handler: @Sendable (String) -> (Int, [String: String], String)

    init(_ handler: @escaping @Sendable (String) -> (Int, [String: String], String)) throws {
        self.handler = handler
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
        guard bindRC == 0, listen(sock, 8) == 0 else {
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
        let listenFD = sock
        DispatchQueue.global().async { [weak self] in
            while let server = self, server.running {
                let client = accept(listenFD, nil, nil)
                if client < 0 { continue }
                server.handle(client: client)
            }
        }
    }

    func hitCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hits
    }

    func stop() {
        running = false
        close(fd)
    }

    private func handle(client: Int32) {
        defer { close(client) }
        var buf = [UInt8](repeating: 0, count: 1_024)
        let n = recv(client, &buf, buf.count, 0)
        guard n > 0, let text = String(bytes: buf.prefix(Int(n)), encoding: .utf8) else { return }
        let path = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        lock.lock()
        hits += 1
        lock.unlock()
        let (status, headers, body) = handler(path)
        var response = "HTTP/1.1 \(status) X\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n\(body)"
        let bytes = Array(response.utf8)
        _ = bytes.withUnsafeBytes { raw in
            send(client, raw.baseAddress, raw.count, 0)
        }
    }
}
