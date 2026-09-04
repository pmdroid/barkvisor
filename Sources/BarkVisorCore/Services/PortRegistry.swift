import Foundation
import GRDB
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A host-local port claimed by a workload (Wave 0: VMs only).
public struct PortClaim: Sendable, Equatable {
    public var hostPort: Int
    public var proto: String
    public var workloadKind: String
    public var workloadId: String
    public var workloadName: String

    public init(
        hostPort: Int,
        proto: String,
        workloadKind: String,
        workloadId: String,
        workloadName: String,
    ) {
        self.hostPort = hostPort
        self.proto = proto
        self.workloadKind = workloadKind
        self.workloadId = workloadId
        self.workloadName = workloadName
    }
}

/// Host-local port occupancy from configured NAT `hostfwd` rules.
///
/// Wave 0: config-vs-config on write + TCP bind probe at start.
/// `nextFree` is guest-port-first, then the next unused host port (PAS-228).
/// App ports stay deferred.
public enum PortRegistry {
    /// Claims from VMs whose effective mode allows port forwards (NAT / implicit NAT).
    public static func claims(db: Database, excludingVM: String? = nil) throws -> [PortClaim] {
        let networks = try Dictionary(
            uniqueKeysWithValues: Network.fetchAll(db).map { ($0.id, $0) },
        )
        var result: [PortClaim] = []
        for vm in try VM.fetchAll(db) {
            if let excludingVM, vm.id == excludingVM { continue }
            let network = vm.networkId.flatMap { networks[$0] }
            let mode = (try? NetworkCapability.effectiveMode(of: network)) ?? .nat
            guard mode.allowsPortForwards else { continue }
            for rule in vm.decodedPortForwards {
                result.append(
                    PortClaim(
                        hostPort: rule.hostPort,
                        proto: Self.normalizedProtocol(rule.protocol),
                        workloadKind: "vm",
                        workloadId: vm.id,
                        workloadName: vm.name,
                    ),
                )
            }
        }
        return result
    }

    /// Reject duplicate hostPort+proto in `rules`, then reject collisions with other VMs.
    public static func assertAvailable(
        _ rules: [PortForwardRule],
        excludingVM: String? = nil,
        db: Database,
    ) throws {
        try assertUnique(rules)
        guard !rules.isEmpty else { return }
        var occupied: [String: PortClaim] = [:]
        for claim in try claims(db: db, excludingVM: excludingVM) {
            let key = claimKey(port: claim.hostPort, proto: claim.proto)
            if occupied[key] == nil { occupied[key] = claim }
        }
        for rule in rules {
            let proto = normalizedProtocol(rule.protocol)
            if let occupant = occupied[claimKey(port: rule.hostPort, proto: proto)] {
                throw BarkVisorError.portInUse(
                    "Host port \(rule.hostPort)/\(proto) is already claimed by "
                        + "\(occupant.workloadKind) \"\(occupant.workloadName)\". "
                        + "Change this VM's host port.",
                )
            }
        }
    }

    public static func assertAvailable(
        _ rules: [PortForwardRule],
        excludingVM: String? = nil,
        db pool: DatabasePool,
    ) async throws {
        try await pool.read { db in
            try assertAvailable(rules, excludingVM: excludingVM, db: db)
        }
    }

    /// Host port at `preferred` if free, otherwise the next unused port of `proto`.
    /// Occupied = NAT `hostfwd` claims (PAS-64) plus `extraOccupied`, then TCP bind probe.
    public static func nextFree(
        preferred: Int,
        proto: String,
        excludingVM: String? = nil,
        extraOccupied: [Int] = [],
        db: Database,
    ) throws -> Int {
        let normalized = normalizedProtocol(proto)
        var occupied = Set(extraOccupied)
        for claim in try claims(db: db, excludingVM: excludingVM) where claim.proto == normalized {
            occupied.insert(claim.hostPort)
        }
        let start = min(max(preferred, 1), 65_535)
        for port in start ... 65_535 {
            if occupied.contains(port) { continue }
            if !probeListen(port: port, proto: normalized) { continue }
            return port
        }
        throw BarkVisorError.portInUse(
            "No free host port at or above \(start)/\(normalized).",
        )
    }

    public static func nextFree(
        preferred: Int,
        proto: String,
        excludingVM: String? = nil,
        extraOccupied: [Int] = [],
        db pool: DatabasePool,
    ) async throws -> Int {
        try await pool.read { db in
            try nextFree(
                preferred: preferred,
                proto: proto,
                excludingVM: excludingVM,
                extraOccupied: extraOccupied,
                db: db,
            )
        }
    }

    /// Same hostPort+proto twice in one request is also a conflict.
    public static func assertUnique(_ rules: [PortForwardRule]) throws {
        var seen: Set<String> = []
        for rule in rules {
            let proto = normalizedProtocol(rule.protocol)
            let key = claimKey(port: rule.hostPort, proto: proto)
            if seen.contains(key) {
                throw BarkVisorError.portInUse(
                    "Host port \(rule.hostPort)/\(proto) is claimed more than once on this VM.",
                )
            }
            seen.insert(key)
        }
    }

    /// Bind test on 0.0.0.0 and 127.0.0.1 without `SO_REUSEADDR`.
    /// QEMU NAT `hostfwd` uses INADDR_ANY; Coding Agent ttyd uses loopback (PAS-272).
    public static func probeListen(port: Int, proto: String) -> Bool {
        switch normalizedProtocol(proto) {
        case "tcp": return isPortFree(port, sockType: streamSockType)
        case "udp": return isPortFree(port, sockType: dgramSockType)
        default: return true
        }
    }

    public static func normalizedProtocol(_ proto: String) -> String {
        proto.lowercased()
    }

    private static func claimKey(port: Int, proto: String) -> String {
        "\(port)/\(proto)"
    }

    private static var streamSockType: Int32 {
        #if os(Linux)
            Int32(SOCK_STREAM.rawValue)
        #else
            SOCK_STREAM
        #endif
    }

    private static var dgramSockType: Int32 {
        #if os(Linux)
            Int32(SOCK_DGRAM.rawValue)
        #else
            SOCK_DGRAM
        #endif
    }

    /// Free only if both INADDR_ANY and 127.0.0.1 can bind `port`.
    private static func isPortFree(_ port: Int, sockType: Int32) -> Bool {
        isBindFree(port, saddr: INADDR_ANY, sockType: sockType)
            && isBindFree(port, saddr: in_addr_t(INADDR_LOOPBACK).bigEndian, sockType: sockType)
    }

    private static func isBindFree(_ port: Int, saddr: in_addr_t, sockType: Int32) -> Bool {
        let fd = socket(AF_INET, sockType, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: saddr)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bindResult == 0
    }
}
