import Foundation
import GRDB

public struct WorkloadServiceObservation: Codable, Equatable, Sendable {
    public var name: String
    public var role: String
    public var running: Bool
    public var exitCode: Int?
    public var health: String
    public var required: Bool

    public init(
        name: String,
        role: String,
        running: Bool,
        exitCode: Int? = nil,
        health: String,
        required: Bool = true,
    ) {
        self.name = name
        self.role = role
        self.running = running
        self.exitCode = exitCode
        self.health = health
        self.required = required
    }

    public static let roleLongRunning = "long_running"
    public static let roleOneShot = "one_shot"
}

public struct WorkloadObservation: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord,
    TableRecord {
    public static let databaseTableName = "workload_observations"

    public var id: String
    public var sequence: Int
    public var appliedGeneration: Int
    public var runtimeIdentity: String?
    public var processState: String
    public var readiness: String
    public var condition: String
    public var observedAt: String
    public var error: String?
    public var freshness: String
    public var enforcedCpu: Int?
    public var enforcedMemoryMb: Int?
    public var servicesJson: String?

    public init(
        id: String,
        sequence: Int,
        appliedGeneration: Int,
        runtimeIdentity: String? = nil,
        processState: String,
        readiness: String,
        condition: String,
        observedAt: String,
        error: String? = nil,
        freshness: String,
        enforcedCpu: Int? = nil,
        enforcedMemoryMb: Int? = nil,
        servicesJson: String? = nil,
    ) {
        self.id = id
        self.sequence = sequence
        self.appliedGeneration = appliedGeneration
        self.runtimeIdentity = runtimeIdentity
        self.processState = processState
        self.readiness = readiness
        self.condition = condition
        self.observedAt = observedAt
        self.error = error
        self.freshness = freshness
        self.enforcedCpu = enforcedCpu
        self.enforcedMemoryMb = enforcedMemoryMb
        self.servicesJson = servicesJson
    }

    public var services: [WorkloadServiceObservation] {
        guard let servicesJson, let data = servicesJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([WorkloadServiceObservation].self, from: data)) ?? []
    }

    public static func encodeServices(_ services: [WorkloadServiceObservation]) -> String? {
        guard let data = try? JSONEncoder().encode(services) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

public struct WorkloadDeliveredView: Codable, Equatable, Sendable {
    public var id: String
    public var configurationGeneration: Int
    public var appliedGeneration: Int
    public var processState: String
    public var readiness: String
    public var condition: String
    public var freshness: String
    public var observedAt: String?
    public var error: String?

    public init(
        id: String,
        configurationGeneration: Int,
        appliedGeneration: Int,
        processState: String,
        readiness: String,
        condition: String,
        freshness: String,
        observedAt: String? = nil,
        error: String? = nil,
    ) {
        self.id = id
        self.configurationGeneration = configurationGeneration
        self.appliedGeneration = appliedGeneration
        self.processState = processState
        self.readiness = readiness
        self.condition = condition
        self.freshness = freshness
        self.observedAt = observedAt
        self.error = error
    }
}
