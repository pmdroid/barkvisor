import Foundation

/// Workload rollup (PAS-79 / PAS-65).
/// Wave 0: `stopped|starting|running|degraded|failed`.
/// PAS-65 adds `guest_ready` when a guest agent is fresh or HTTP/TCP probes pass.
public enum WorkloadHealth: String, Codable, Sendable, CaseIterable {
    case unknown
    case stopped
    case starting
    case running
    case guestReady = "guest_ready"
    case degraded
    case failed
}

public enum WorkloadHealthCheckStatus: String, Codable, Sendable {
    case pass
    case fail
    case skip
}

public struct WorkloadHealthCheck: Codable, Equatable, Sendable {
    public var name: String
    public var status: WorkloadHealthCheckStatus
    public var message: String?

    public init(name: String, status: WorkloadHealthCheckStatus, message: String? = nil) {
        self.name = name
        self.status = status
        self.message = message
    }
}

/// Inputs for health projection. `nil` means the signal was not observed (skip).
///
/// Sources: `qemuProcess` (VMManager), `qmp` (socket), `guestAgent` /
/// `lastSeenAt` (guest_info), `http`/`tcp` (HealthProbeService), `lastError`.
public struct WorkloadHealthSignals: Equatable, Sendable {
    public var qemuProcess: Bool?
    public var qmp: Bool?
    public var guestAgent: Bool?
    public var lastSeenAt: String?
    public var lastError: String?
    public var http: Bool?
    public var tcp: Bool?
    public var httpConfigured: Bool
    public var tcpConfigured: Bool

    public static let unobserved = WorkloadHealthSignals()

    public init(
        qemuProcess: Bool? = nil,
        qmp: Bool? = nil,
        guestAgent: Bool? = nil,
        lastSeenAt: String? = nil,
        lastError: String? = nil,
        http: Bool? = nil,
        tcp: Bool? = nil,
        httpConfigured: Bool = false,
        tcpConfigured: Bool = false,
    ) {
        self.qemuProcess = qemuProcess
        self.qmp = qmp
        self.guestAgent = guestAgent
        self.lastSeenAt = lastSeenAt
        self.lastError = lastError
        self.http = http
        self.tcp = tcp
        self.httpConfigured = httpConfigured
        self.tcpConfigured = tcpConfigured
    }

    public var probesConfigured: Bool {
        httpConfigured || tcpConfigured
    }

    public var probesFailed: Bool {
        http == false || tcp == false
    }

    public var probesPassed: Bool {
        if probesFailed { return false }
        let observed = [http, tcp].compactMap(\.self)
        return !observed.isEmpty && observed.allSatisfy(\.self)
    }
}

public struct WorkloadHealthStatus: Codable, Equatable, Sendable {
    public var health: WorkloadHealth
    public var checks: [WorkloadHealthCheck]
    public var updatedAt: String
    public var lastError: String?

    public init(
        health: WorkloadHealth,
        checks: [WorkloadHealthCheck],
        updatedAt: String,
        lastError: String? = nil,
    ) {
        self.health = health
        self.checks = checks
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

public struct WorkloadHealthSummaryItem: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: String
    public var health: WorkloadHealth
    public var lastError: String?

    public init(
        id: String,
        name: String,
        kind: String = "vm",
        health: WorkloadHealth,
        lastError: String? = nil,
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.health = health
        self.lastError = lastError
    }
}

public struct WorkloadHealthSummary: Codable, Equatable, Sendable {
    public var counts: [String: Int]
    public var items: [WorkloadHealthSummaryItem]
    public var updatedAt: String

    public init(counts: [String: Int], items: [WorkloadHealthSummaryItem], updatedAt: String) {
        self.counts = counts
        self.items = items
        self.updatedAt = updatedAt
    }
}

/// Process-level `/api/health` body (PAS-79). `status` stays `ok` when every
/// required check passes so existing probes keep working.
public struct ProcessHealthStatus: Codable, Equatable, Sendable {
    public var status: String
    public var apiVersion: Int
    public var checks: [WorkloadHealthCheck]
    public var updatedAt: String

    public init(
        status: String,
        checks: [WorkloadHealthCheck],
        updatedAt: String,
        apiVersion: Int = APIContract.version,
    ) {
        self.status = status
        self.apiVersion = apiVersion
        self.checks = checks
        self.updatedAt = updatedAt
    }
}
