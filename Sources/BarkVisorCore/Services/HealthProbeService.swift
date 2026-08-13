#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation
import GRDB

/// Last observed HTTP/TCP probe results for one VM (PAS-65).
///
/// `nil` on `http`/`tcp` means the check is unconfigured or not yet observed.
public struct HealthProbeResults: Equatable, Sendable {
    public var http: Bool?
    public var tcp: Bool?
    public var httpConfigured: Bool
    public var tcpConfigured: Bool

    public static let unobserved = HealthProbeResults()

    public init(
        http: Bool? = nil,
        tcp: Bool? = nil,
        httpConfigured: Bool = false,
        tcpConfigured: Bool = false,
    ) {
        self.http = http
        self.tcp = tcp
        self.httpConfigured = httpConfigured
        self.tcpConfigured = tcpConfigured
    }

    public var configured: Bool {
        httpConfigured || tcpConfigured
    }

    public var failed: Bool {
        http == false || tcp == false
    }

    /// True when every configured probe that has a result passed, and at least one ran.
    public var passed: Bool {
        if failed { return false }
        let observed = [http, tcp].compactMap(\.self)
        return !observed.isEmpty && observed.allSatisfy(\.self)
    }
}

/// Injectable HTTP/TCP transport so tests do not bind real sockets.
public struct HealthProbeTransport: Sendable {
    public var http: @Sendable (String, Int, String, TimeInterval, Int?) async -> Bool
    public var tcp: @Sendable (String, Int, TimeInterval) async -> Bool

    public init(
        http: @escaping @Sendable (String, Int, String, TimeInterval, Int?) async -> Bool,
        tcp: @escaping @Sendable (String, Int, TimeInterval) async -> Bool,
    ) {
        self.http = http
        self.tcp = tcp
    }

    public static let live = HealthProbeTransport(
        http: { host, port, path, timeout, expected in
            await HealthProbeLive.http(
                host: host, port: port, path: path, timeout: timeout, expectedStatus: expected,
            )
        },
        tcp: { host, port, timeout in
            HealthProbeLive.tcp(host: host, port: port, timeout: timeout)
        },
    )
}

/// Per-host HTTP/TCP probe runner. Results stay in memory; config lives on `vms.healthJson`.
///
/// Probes only the owner Device (localhost hostfwd or a non-SLIRP guest IP). They never
/// call a peer or controller — local SQLite still owns runtime (PAS-47 / PAS-90).
public actor HealthProbeService {
    private struct State {
        var fingerprint: String
        var httpConfigured: Bool
        var tcpConfigured: Bool
        var consecutiveHTTPPass = 0
        var consecutiveHTTPFail = 0
        var consecutiveTCPPass = 0
        var consecutiveTCPFail = 0
        var http: Bool?
        var tcp: Bool?
        var lastAttempt: Date?
    }

    private let dbPool: DatabasePool?
    private let transport: HealthProbeTransport
    private var states: [String: State] = [:]

    public init(dbPool: DatabasePool? = nil, transport: HealthProbeTransport = .live) {
        self.dbPool = dbPool
        self.transport = transport
    }

    public func results(for vmID: String) -> HealthProbeResults {
        guard let state = states[vmID] else { return .unobserved }
        return results(from: state)
    }

    /// Prefer this over `results(for: vmID)` so configured flags come from spec
    /// even before the first probe (or after a config reset).
    public func results(for vm: VM) -> HealthProbeResults {
        guard let spec = vm.decodedHealth, spec.hasProbes else { return .unobserved }
        let cached = states[vm.id]
        let same = cached?.fingerprint == spec.fingerprint
        return HealthProbeResults(
            http: same ? cached?.http : nil,
            tcp: same ? cached?.tcp : nil,
            httpConfigured: spec.http != nil,
            tcpConfigured: spec.tcp != nil,
        )
    }

    public func reset(vmID: String) {
        states.removeValue(forKey: vmID)
    }

    /// Run configured probes once and update the in-memory cache.
    @discardableResult
    public func probeNow(
        vm: VM,
        guestIPs: [String] = [],
        now: Date = Date(),
    ) async -> HealthProbeResults {
        guard let spec = vm.decodedHealth, spec.hasProbes else {
            states.removeValue(forKey: vm.id)
            return .unobserved
        }
        await run(vm: vm, spec: spec, guestIPs: guestIPs, now: now, force: true)
        return results(for: vm.id)
    }

    /// Poll every running VM whose interval has elapsed. Used by the daemon timer.
    public func pollDue(now: Date = Date()) async {
        guard let dbPool else { return }
        let vms: [VM]
        do {
            vms = try await dbPool.read { db in
                try VM.fetchAll(db)
            }
        } catch {
            Log.vm.warning("health probe list failed: \(error.localizedDescription)")
            return
        }
        let ips = await GuestHealthStore.ipsByVM(ids: vms.map(\.id), db: dbPool)
        for vm in vms {
            let state = VMState.parse(vm.state)
            guard state == .running || state == .starting else {
                states.removeValue(forKey: vm.id)
                continue
            }
            guard let spec = vm.decodedHealth, spec.hasProbes else {
                states.removeValue(forKey: vm.id)
                continue
            }
            await run(
                vm: vm,
                spec: spec,
                guestIPs: ips[vm.id] ?? [],
                now: now,
                force: false,
            )
        }
    }

    // MARK: - Private

    private func run(
        vm: VM,
        spec: WorkloadHealthSpec,
        guestIPs: [String],
        now: Date,
        force: Bool,
    ) async {
        let fingerprint = spec.fingerprint
        var state = states[vm.id] ?? State(
            fingerprint: fingerprint,
            httpConfigured: spec.http != nil,
            tcpConfigured: spec.tcp != nil,
        )
        if state.fingerprint != fingerprint {
            state = State(
                fingerprint: fingerprint,
                httpConfigured: spec.http != nil,
                tcpConfigured: spec.tcp != nil,
            )
        }
        if !force, let last = state.lastAttempt,
           now.timeIntervalSince(last) < spec.resolvedInterval {
            states[vm.id] = state
            return
        }
        state.lastAttempt = now

        if let http = spec.http {
            if let target = HealthProbeTarget.resolve(
                port: http.port, vm: vm, guestIPs: guestIPs,
            ) {
                let ok = await transport.http(
                    target.host, target.port, http.normalizedPath, spec.resolvedTimeout,
                    http.expectedStatus,
                )
                if ok {
                    state.consecutiveHTTPPass += 1
                    state.consecutiveHTTPFail = 0
                    if state.consecutiveHTTPPass >= spec.resolvedHealthyThreshold {
                        state.http = true
                    }
                } else {
                    state.consecutiveHTTPFail += 1
                    state.consecutiveHTTPPass = 0
                    if state.consecutiveHTTPFail >= spec.resolvedUnhealthyThreshold {
                        state.http = false
                    }
                }
            }
        } else {
            state.http = nil
            state.consecutiveHTTPPass = 0
            state.consecutiveHTTPFail = 0
        }

        if let tcp = spec.tcp {
            if let target = HealthProbeTarget.resolve(
                port: tcp.port, vm: vm, guestIPs: guestIPs,
            ) {
                let ok = await transport.tcp(target.host, target.port, spec.resolvedTimeout)
                if ok {
                    state.consecutiveTCPPass += 1
                    state.consecutiveTCPFail = 0
                    if state.consecutiveTCPPass >= spec.resolvedHealthyThreshold {
                        state.tcp = true
                    }
                } else {
                    state.consecutiveTCPFail += 1
                    state.consecutiveTCPPass = 0
                    if state.consecutiveTCPFail >= spec.resolvedUnhealthyThreshold {
                        state.tcp = false
                    }
                }
            }
        } else {
            state.tcp = nil
            state.consecutiveTCPPass = 0
            state.consecutiveTCPFail = 0
        }

        states[vm.id] = state
    }

    private func results(from state: State) -> HealthProbeResults {
        HealthProbeResults(
            http: state.http,
            tcp: state.tcp,
            httpConfigured: state.httpConfigured,
            tcpConfigured: state.tcpConfigured,
        )
    }
}

/// Resolves a guest probe destination. Prefer hostfwd so NAT VMs are reachable.
public enum HealthProbeTarget: Equatable, Sendable {
    public struct Resolved: Equatable, Sendable {
        public var host: String
        public var port: Int
        public var via: String
    }

    /// QEMU user-net guest address — not reachable from the host.
    public static let slirpGuestIPv4 = "10.0.2.15"

    public static func resolve(port: Int, vm: VM, guestIPs: [String]) -> Resolved? {
        if let rule = vm.decodedPortForwards.first(where: {
            $0.protocol == "tcp" && $0.guestPort == port
        }) {
            return Resolved(host: "127.0.0.1", port: rule.hostPort, via: "hostfwd")
        }
        for ip in guestIPs where isReachableGuestIPv4(ip) {
            return Resolved(host: ip, port: port, via: "guest")
        }
        return nil
    }

    public static func isReachableGuestIPv4(_ ip: String) -> Bool {
        if ip == slirpGuestIPv4 { return false }
        if ip.hasPrefix("127.") { return false }
        let parts = ip.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ UInt8($0) != nil }) else { return false }
        return true
    }
}

/// Guest-info helpers shared by health projection and the probe runner.
public enum GuestHealthStore {
    public static func lastSeen(ids: [String], db: DatabasePool) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = try await db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }
        var seen: [String: String] = [:]
        for record in records where idSet.contains(record.vmId) {
            seen[record.vmId] = record.updatedAt
        }
        return seen
    }

    public static func ipsByVM(ids: [String], db: DatabasePool) async -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = await (try? db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }) ?? []
        var out: [String: [String]] = [:]
        for record in records where idSet.contains(record.vmId) {
            out[record.vmId] = JSONColumnCoding.decodeArray(String.self, from: record.ipAddresses)
                ?? []
        }
        return out
    }
}

enum HealthProbeLive {
    static func http(
        host: String,
        port: Int,
        path: String,
        timeout: TimeInterval,
        expectedStatus: Int?,
    ) async -> Bool {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.percentEncodedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = components.url else { return false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("BarkVisor-health/1", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if let expectedStatus {
                return http.statusCode == expectedStatus
            }
            return (200 ... 399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static func tcp(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = PlatformSocket.stream

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let list = result else { return false }
        defer { freeaddrinfo(list) }

        var current: UnsafeMutablePointer<addrinfo>? = list
        while let info = current {
            if connectNonblocking(info.pointee, timeout: timeout) {
                return true
            }
            current = info.pointee.ai_next
        }
        return false
    }

    private static func connectNonblocking(_ info: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.ai_addr, info.ai_addrlen)
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))
        let prc = poll(&pollFD, 1, ms)
        guard prc > 0, (pollFD.revents & Int16(POLLOUT)) != 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }
}
