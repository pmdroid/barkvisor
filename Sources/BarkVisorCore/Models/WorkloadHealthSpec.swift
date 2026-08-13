import Foundation

/// VM guest probe config (PAS-65). Linear also names `exec` for Apps — rejected here.
public struct WorkloadHealthSpec: Codable, Equatable, Sendable {
    public static let defaultIntervalSec = 30
    public static let defaultTimeoutSec = 5
    public static let defaultHealthyThreshold = 1
    public static let defaultUnhealthyThreshold = 3

    public var intervalSec: Int?
    public var timeoutSec: Int?
    public var healthyThreshold: Int?
    public var unhealthyThreshold: Int?
    public var http: WorkloadHealthHTTPCheck?
    public var tcp: WorkloadHealthTCPCheck?
    public var exec: WorkloadHealthExecCheck?

    public init(
        intervalSec: Int? = nil,
        timeoutSec: Int? = nil,
        healthyThreshold: Int? = nil,
        unhealthyThreshold: Int? = nil,
        http: WorkloadHealthHTTPCheck? = nil,
        tcp: WorkloadHealthTCPCheck? = nil,
        exec: WorkloadHealthExecCheck? = nil,
    ) {
        self.intervalSec = intervalSec
        self.timeoutSec = timeoutSec
        self.healthyThreshold = healthyThreshold
        self.unhealthyThreshold = unhealthyThreshold
        self.http = http
        self.tcp = tcp
        self.exec = exec
    }

    public var hasProbes: Bool {
        http != nil || tcp != nil
    }

    public var resolvedInterval: TimeInterval {
        TimeInterval(clamp(intervalSec, default: Self.defaultIntervalSec, min: 5, max: 3_600))
    }

    public var resolvedTimeout: TimeInterval {
        TimeInterval(clamp(timeoutSec, default: Self.defaultTimeoutSec, min: 1, max: 60))
    }

    public var resolvedHealthyThreshold: Int {
        clamp(healthyThreshold, default: Self.defaultHealthyThreshold, min: 1, max: 20)
    }

    public var resolvedUnhealthyThreshold: Int {
        clamp(unhealthyThreshold, default: Self.defaultUnhealthyThreshold, min: 1, max: 20)
    }

    /// Stable identity so the runner can reset consecutive counters on edit.
    public var fingerprint: String {
        WorkloadSpecJSON.encodeHealth(self) ?? ""
    }

    public static func validate(_ spec: WorkloadHealthSpec) throws {
        if spec.exec != nil {
            throw BarkVisorError.badRequest(
                "exec health checks are App-only and not supported on VirtualMachine",
            )
        }
        if let interval = spec.intervalSec, !(5 ... 3_600).contains(interval) {
            throw BarkVisorError.badRequest("health.intervalSec must be 5...3600")
        }
        if let timeout = spec.timeoutSec, !(1 ... 60).contains(timeout) {
            throw BarkVisorError.badRequest("health.timeoutSec must be 1...60")
        }
        if let n = spec.healthyThreshold, !(1 ... 20).contains(n) {
            throw BarkVisorError.badRequest("health.healthyThreshold must be 1...20")
        }
        if let n = spec.unhealthyThreshold, !(1 ... 20).contains(n) {
            throw BarkVisorError.badRequest("health.unhealthyThreshold must be 1...20")
        }
        if let http = spec.http {
            try http.validate()
        }
        if let tcp = spec.tcp {
            try tcp.validate()
        }
    }

    private func clamp(_ value: Int?, default defaultValue: Int, min: Int, max: Int) -> Int {
        Swift.min(Swift.max(value ?? defaultValue, min), max)
    }
}

public struct WorkloadHealthHTTPCheck: Codable, Equatable, Sendable {
    public var path: String
    public var port: Int
    public var expectedStatus: Int?

    public init(path: String, port: Int, expectedStatus: Int? = nil) {
        self.path = path
        self.port = port
        self.expectedStatus = expectedStatus
    }

    public var normalizedPath: String {
        path.hasPrefix("/") ? path : "/\(path)"
    }

    public func validate() throws {
        guard (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("health.http.port must be 1...65535")
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1 ... 256).contains(trimmed.count) else {
            throw BarkVisorError.badRequest("health.http.path must be 1...256 characters")
        }
        guard trimmed.hasPrefix("/"), !trimmed.hasPrefix("//"), !trimmed.contains("://") else {
            throw BarkVisorError.badRequest(
                "health.http.path must be a path starting with / (not a URL)",
            )
        }
        if let expectedStatus, !(100 ... 599).contains(expectedStatus) {
            throw BarkVisorError.badRequest("health.http.expectedStatus must be 100...599")
        }
    }
}

public struct WorkloadHealthTCPCheck: Codable, Equatable, Sendable {
    public var port: Int

    public init(port: Int) {
        self.port = port
    }

    public func validate() throws {
        guard (1 ... 65_535).contains(port) else {
            throw BarkVisorError.badRequest("health.tcp.port must be 1...65535")
        }
    }
}

/// App-only Linear field. Present so a VM spec that includes it is rejected, not dropped.
public struct WorkloadHealthExecCheck: Codable, Equatable, Sendable {
    public var command: [String]

    public init(command: [String]) {
        self.command = command
    }
}
