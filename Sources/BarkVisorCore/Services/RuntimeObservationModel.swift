import Foundation

public enum ObservationFreshness: String, Sendable, Equatable, Codable {
    case fresh
    case stale
    case unknown
}

public enum WorkloadRuntimePhase: String, Sendable, Equatable, Codable {
    case running
    case exited
    case restarting
    case oom
    case unknown
}

public enum WorkloadHealthFact: String, Sendable, Equatable, Codable {
    case healthy
    case unhealthy
    case unknown
}

public struct ServiceObservation: Sendable, Equatable, Codable {
    public var service: String
    public var containerID: String
    public var phase: WorkloadRuntimePhase
    public var health: WorkloadHealthFact

    public init(
        service: String,
        containerID: String,
        phase: WorkloadRuntimePhase,
        health: WorkloadHealthFact,
    ) {
        self.service = service
        self.containerID = containerID
        self.phase = phase
        self.health = health
    }
}

public struct WorkloadObservation: Sendable, Equatable, Codable {
    public var workloadID: String
    public var configurationGeneration: UInt64
    public var observationSequence: UInt64
    public var phase: WorkloadRuntimePhase
    public var health: WorkloadHealthFact
    public var freshness: ObservationFreshness
    public var services: [ServiceObservation]
    public var observedAt: Date?
    public var detail: String?
    public var cpuPercent: Double?
    public var memoryUsedBytes: Int64?

    public init(
        workloadID: String,
        configurationGeneration: UInt64,
        observationSequence: UInt64,
        phase: WorkloadRuntimePhase,
        health: WorkloadHealthFact,
        freshness: ObservationFreshness,
        services: [ServiceObservation],
        observedAt: Date?,
        detail: String?,
        cpuPercent: Double?,
        memoryUsedBytes: Int64?,
    ) {
        self.workloadID = workloadID
        self.configurationGeneration = configurationGeneration
        self.observationSequence = observationSequence
        self.phase = phase
        self.health = health
        self.freshness = freshness
        self.services = services
        self.observedAt = observedAt
        self.detail = detail
        self.cpuPercent = cpuPercent
        self.memoryUsedBytes = memoryUsedBytes
    }

    public static func empty(_ workloadID: String) -> WorkloadObservation {
        WorkloadObservation(
            workloadID: workloadID,
            configurationGeneration: 0,
            observationSequence: 0,
            phase: .unknown,
            health: .unknown,
            freshness: .unknown,
            services: [],
            observedAt: nil,
            detail: nil,
            cpuPercent: nil,
            memoryUsedBytes: nil,
        )
    }
}

public struct ContainerSnapshot: Sendable, Equatable {
    public var workloadID: String
    public var service: String
    public var containerID: String
    public var state: String
    public var status: String
    public var name: String

    public init(
        workloadID: String,
        service: String,
        containerID: String,
        state: String,
        status: String,
        name: String,
    ) {
        self.workloadID = workloadID
        self.service = service
        self.containerID = containerID
        self.state = state
        self.status = status
        self.name = name
    }
}

public struct ReconcileFact: Sendable, Equatable {
    public var workloadID: String
    public var phase: WorkloadRuntimePhase
    public var detail: String?

    public init(workloadID: String, phase: WorkloadRuntimePhase, detail: String?) {
        self.workloadID = workloadID
        self.phase = phase
        self.detail = detail
    }
}

public struct DockerContainerEvent: Sendable, Equatable {
    public var workloadID: String
    public var service: String
    public var containerID: String
    public var action: String
    public var exitCode: Int?
    public var time: Date

    public init(
        workloadID: String,
        service: String,
        containerID: String,
        action: String,
        exitCode: Int?,
        time: Date,
    ) {
        self.workloadID = workloadID
        self.service = service
        self.containerID = containerID
        self.action = action
        self.exitCode = exitCode
        self.time = time
    }
}

public enum QMPObservationKind: String, Sendable, Equatable {
    case shutdown
    case guestPanicked
    case reset
}

public enum ObservationNotice: Sendable, Equatable {
    case observation(WorkloadObservation)
    case resync
}

public enum DockerEventDelivery: Sendable, Equatable {
    case line(String)
    case gap
}

public struct DockerEventSubscription: Sendable {
    public var stream: AsyncStream<DockerEventDelivery>
    public var cancel: @Sendable () -> Void

    public init(stream: AsyncStream<DockerEventDelivery>, cancel: @escaping @Sendable () -> Void) {
        self.stream = stream
        self.cancel = cancel
    }
}

public protocol DockerEventProducing: Sendable {
    func open(identity: DockerRuntimeIdentity) -> DockerEventSubscription
}

public enum ManagedStatsCollect: Sendable, Equatable {
    case fresh([String: DockerStatsTotals])
    case failed
}

public enum ContainerListCollect: Sendable {
    case fresh([ContainerSnapshot])
    case failed
}

enum ObservationRollup {
    static func phase(state: String, status: String) -> WorkloadRuntimePhase {
        let lowered = status.lowercased()
        if lowered.contains("oomkilled") {
            return .oom
        }
        switch state.lowercased() {
        case "running":
            return .running
        case "restarting":
            return .restarting
        case "exited", "dead", "stopped":
            return .exited
        default:
            return .unknown
        }
    }

    static func health(status: String) -> WorkloadHealthFact {
        if status.contains("(healthy)") { return .healthy }
        if status.contains("(unhealthy)") { return .unhealthy }
        return .unknown
    }

    static func phase(action: String) -> WorkloadRuntimePhase? {
        switch action {
        case "start", "unpause":
            return .running
        case "die", "stop", "destroy", "kill":
            return .exited
        case "oom":
            return .oom
        case "restart":
            return .restarting
        default:
            return nil
        }
    }

    static func health(action: String) -> WorkloadHealthFact? {
        switch action {
        case "health_status: healthy":
            return .healthy
        case "health_status: unhealthy":
            return .unhealthy
        case "oom":
            return .unhealthy
        default:
            return nil
        }
    }

    static func workloadPhase(_ services: [ServiceObservation]) -> WorkloadRuntimePhase {
        if services.contains(where: { $0.phase == .oom }) { return .oom }
        if services.contains(where: { $0.phase == .restarting }) { return .restarting }
        if services.contains(where: { $0.phase == .running }) { return .running }
        if !services.isEmpty, services.allSatisfy({ $0.phase == .exited }) { return .exited }
        return .unknown
    }

    static func workloadHealth(_ services: [ServiceObservation]) -> WorkloadHealthFact {
        if services.contains(where: { $0.health == .unhealthy }) { return .unhealthy }
        if !services.isEmpty, services.allSatisfy({ $0.health == .healthy }) { return .healthy }
        return .unknown
    }
}

enum DockerEventDecoding {
    static func parse(
        line: String,
        workloadLabel: String = ComposeAllowlist.workloadLabelKey,
    ) -> DockerContainerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let type = json["Type"] as? String, type != "container" { return nil }
        guard let action = json["Action"] as? String,
              let actor = json["Actor"] as? [String: Any],
              let attributes = actor["Attributes"] as? [String: Any],
              let workloadID = attributes[workloadLabel] as? String,
              !workloadID.isEmpty
        else { return nil }
        let containerID = (actor["ID"] as? String) ?? ""
        guard !containerID.isEmpty else { return nil }
        let service = (attributes["com.docker.compose.service"] as? String).flatMap { value in
            value.isEmpty ? nil : value
        } ?? containerID
        let exitCode = (attributes["exitCode"] as? String).flatMap(Int.init)
        let time = eventTime(json)
        return DockerContainerEvent(
            workloadID: workloadID,
            service: service,
            containerID: containerID,
            action: action,
            exitCode: exitCode,
            time: time,
        )
    }

    static func parseList(_ output: String) -> [ContainerSnapshot] {
        output.split(whereSeparator: \.isNewline).compactMap { row in
            parseListRow(String(row))
        }
    }

    static func parseListRow(_ row: String) -> ContainerSnapshot? {
        let parts = row.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 5 else { return nil }
        let containerID = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let workloadID = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !containerID.isEmpty, !workloadID.isEmpty else { return nil }
        let service = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = parts.count > 5 ? parts[5] : containerID
        return ContainerSnapshot(
            workloadID: workloadID,
            service: service.isEmpty ? containerID : service,
            containerID: containerID,
            state: parts[3].trimmingCharacters(in: .whitespacesAndNewlines),
            status: parts[4].trimmingCharacters(in: .whitespacesAndNewlines),
            name: name,
        )
    }

    private static func eventTime(_ json: [String: Any]) -> Date {
        if let nano = json["timeNano"] as? Double {
            return Date(timeIntervalSince1970: nano / 1_000_000_000)
        }
        if let nano = json["timeNano"] as? Int {
            return Date(timeIntervalSince1970: Double(nano) / 1_000_000_000)
        }
        if let seconds = json["time"] as? Double {
            return Date(timeIntervalSince1970: seconds)
        }
        if let seconds = json["time"] as? Int {
            return Date(timeIntervalSince1970: Double(seconds))
        }
        return Date(timeIntervalSince1970: 0)
    }
}
