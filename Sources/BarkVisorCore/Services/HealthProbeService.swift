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
    public var httpUnreachable: Bool
    public var tcpUnreachable: Bool

    public static let unobserved = HealthProbeResults()

    public init(
        http: Bool? = nil,
        tcp: Bool? = nil,
        httpConfigured: Bool = false,
        tcpConfigured: Bool = false,
        httpUnreachable: Bool = false,
        tcpUnreachable: Bool = false,
    ) {
        self.http = http
        self.tcp = tcp
        self.httpConfigured = httpConfigured
        self.tcpConfigured = tcpConfigured
        self.httpUnreachable = httpUnreachable
        self.tcpUnreachable = tcpUnreachable
    }

    public var configured: Bool {
        httpConfigured || tcpConfigured
    }

    public var failed: Bool {
        http == false || tcp == false
    }

    /// True when every configured probe has been observed and passed.
    public var passed: Bool {
        if httpConfigured && http != true { return false }
        if tcpConfigured && tcp != true { return false }
        return httpConfigured || tcpConfigured
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
            await HealthProbeLive.tcp(host: host, port: port, timeout: timeout)
        },
    )
}

/// Per-host HTTP/TCP probe runner. Results stay in memory; config lives on `vms.healthJson`.
///
/// Probes only the owner Device (localhost hostfwd or a VM-bound bridged guest IP).
/// They never call a peer or controller — local SQLite still owns runtime (PAS-47 / PAS-90).
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
        var httpUnreachable = false
        var tcpUnreachable = false
        var lastAttempt: Date?
    }

    private let dbPool: DatabasePool?
    private let transport: HealthProbeTransport
    private var states: [String: State] = [:]
    /// Bumped on each attempt and whenever cached state is cleared so a
    /// suspended run cannot restore results after the VM became ineligible.
    private var generations: [String: UInt64] = [:]
    private var probeBusy: Set<String> = []
    private var probeWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

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
            httpUnreachable: same && (cached?.httpUnreachable ?? false),
            tcpUnreachable: same && (cached?.tcpUnreachable ?? false),
        )
    }

    public func reset(vmID: String) {
        clearState(vmID)
    }

    /// Run configured probes once and update the in-memory cache.
    @discardableResult
    public func probeNow(
        vm: VM,
        guestIPs: [String] = [],
        now: Date = Date(),
        policy: HealthProbePolicy? = nil,
    ) async -> HealthProbeResults {
        guard let spec = vm.decodedHealth, spec.hasProbes else {
            clearState(vm.id)
            return .unobserved
        }
        let resolved = await destinationPolicy(for: vm, override: policy)
        await run(vm: vm, spec: spec, guestIPs: guestIPs, now: now, force: true, policy: resolved)
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
        let networks = await loadNetworks(ids: Set(vms.compactMap(\.networkId)), db: dbPool)
        var jobs: [(
            vm: VM,
            spec: WorkloadHealthSpec,
            guestIPs: [String],
            policy: HealthProbePolicy,
        )] = []
        jobs.reserveCapacity(vms.count)
        for vm in vms {
            let state = VMState.parse(vm.state)
            guard state == .running || state == .starting else {
                clearState(vm.id)
                continue
            }
            guard let spec = vm.decodedHealth, spec.hasProbes else {
                clearState(vm.id)
                continue
            }
            let network = vm.networkId.flatMap { networks[$0] }
            jobs.append((vm, spec, ips[vm.id] ?? [], HealthProbeTarget.policy(for: network)))
        }

        // Bound in-flight probes so a fleet of unreachable targets cannot
        // serialize N × timeout against the 5s scheduler tick.
        let limit = 4
        await withTaskGroup(of: Void.self) { group in
            var started = 0
            for job in jobs {
                if started >= limit {
                    await group.next()
                }
                group.addTask {
                    await self.run(
                        vm: job.vm,
                        spec: job.spec,
                        guestIPs: job.guestIPs,
                        now: now,
                        force: false,
                        policy: job.policy,
                    )
                }
                started += 1
            }
        }
    }

    // MARK: - Private

    private func run(
        vm: VM,
        spec: WorkloadHealthSpec,
        guestIPs: [String],
        now: Date,
        force: Bool,
        policy: HealthProbePolicy,
    ) async {
        await acquireProbe(vm.id)
        defer { releaseProbe(vm.id) }

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
        let generation = (generations[vm.id] ?? 0) &+ 1
        generations[vm.id] = generation
        // Persist lastAttempt before awaiting transport so a later pollDue
        // does not immediately schedule another attempt for the same interval.
        states[vm.id] = state

        await applyHTTP(spec: spec, vm: vm, guestIPs: guestIPs, policy: policy, state: &state)
        await applyTCP(spec: spec, vm: vm, guestIPs: guestIPs, policy: policy, state: &state)

        guard generations[vm.id] == generation else { return }
        states[vm.id] = state
    }

    private func applyHTTP(
        spec: WorkloadHealthSpec,
        vm: VM,
        guestIPs: [String],
        policy: HealthProbePolicy,
        state: inout State,
    ) async {
        guard let http = spec.http else {
            state.http = nil
            state.httpUnreachable = false
            state.consecutiveHTTPPass = 0
            state.consecutiveHTTPFail = 0
            return
        }
        guard let target = HealthProbeTarget.resolve(
            port: http.port, vm: vm, guestIPs: guestIPs, policy: policy,
        ) else {
            // Drop stale pass/fail so a lost guest IP cannot keep guest_ready.
            state.http = nil
            state.httpUnreachable = true
            state.consecutiveHTTPPass = 0
            state.consecutiveHTTPFail = 0
            return
        }
        state.httpUnreachable = false
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

    private func applyTCP(
        spec: WorkloadHealthSpec,
        vm: VM,
        guestIPs: [String],
        policy: HealthProbePolicy,
        state: inout State,
    ) async {
        guard let tcp = spec.tcp else {
            state.tcp = nil
            state.tcpUnreachable = false
            state.consecutiveTCPPass = 0
            state.consecutiveTCPFail = 0
            return
        }
        guard let target = HealthProbeTarget.resolve(
            port: tcp.port, vm: vm, guestIPs: guestIPs, policy: policy,
        ) else {
            state.tcp = nil
            state.tcpUnreachable = true
            state.consecutiveTCPPass = 0
            state.consecutiveTCPFail = 0
            return
        }
        state.tcpUnreachable = false
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

    private func destinationPolicy(
        for vm: VM,
        override: HealthProbePolicy?,
    ) async -> HealthProbePolicy {
        if let override { return override }
        guard let dbPool, let networkId = vm.networkId else { return .hostfwdOnly }
        let network = try? await dbPool.read { db in
            try Network.fetchOne(db, key: networkId)
        }
        return HealthProbeTarget.policy(for: network)
    }

    private func loadNetworks(ids: Set<String>, db: DatabasePool) async -> [String: Network] {
        guard !ids.isEmpty else { return [:] }
        let rows = await (try? db.read { db in
            try Network.fetchAll(db)
        }) ?? []
        var out: [String: Network] = [:]
        for row in rows where ids.contains(row.id) {
            out[row.id] = row
        }
        return out
    }

    private func clearState(_ vmID: String) {
        states.removeValue(forKey: vmID)
        generations[vmID] = (generations[vmID] ?? 0) &+ 1
    }

    private func acquireProbe(_ id: String) async {
        while probeBusy.contains(id) {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                probeWaiters[id, default: []].append(cont)
            }
        }
        probeBusy.insert(id)
    }

    private func releaseProbe(_ id: String) {
        probeBusy.remove(id)
        guard var queue = probeWaiters[id], !queue.isEmpty else {
            probeWaiters[id] = nil
            return
        }
        let next = queue.removeFirst()
        probeWaiters[id] = queue.isEmpty ? nil : queue
        next.resume()
    }

    private func results(from state: State) -> HealthProbeResults {
        HealthProbeResults(
            http: state.http,
            tcp: state.tcp,
            httpConfigured: state.httpConfigured,
            tcpConfigured: state.tcpConfigured,
            httpUnreachable: state.httpUnreachable,
            tcpUnreachable: state.tcpUnreachable,
        )
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
