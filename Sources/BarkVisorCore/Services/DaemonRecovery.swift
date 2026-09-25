import Foundation
import GRDB

public struct DaemonRecoveryPlan: Equatable, Sendable {
    public var records: [DurableWorkloadOperation]
    public var commands: [WorkloadSocketCommand]

    public init(records: [DurableWorkloadOperation], commands: [WorkloadSocketCommand]) {
        self.records = records
        self.commands = commands
    }
}

public enum DaemonRecovery {
    public static func reconcile(
        records: [DurableWorkloadOperation],
        running: Set<String>,
        present: Set<String>,
    ) -> DaemonRecoveryPlan {
        var updated = records
        var commands: [WorkloadSocketCommand] = []
        for index in updated.indices where updated[index].phase == "accepted" {
            let record = updated[index]
            switch record.kind {
            case "delete":
                if present.contains(record.workloadID) {
                    commands.append(command(record))
                } else {
                    updated[index].phase = "completed"
                    updated[index].state = "deleted"
                }
            case "start", "update":
                if running.contains(record.workloadID) {
                    updated[index].phase = "completed"
                    updated[index].state = "running"
                } else {
                    commands.append(command(record))
                }
            case "stop":
                if running.contains(record.workloadID) {
                    commands.append(command(record))
                } else {
                    updated[index].phase = "completed"
                    updated[index].state = "stopped"
                }
            default:
                break
            }
        }
        return DaemonRecoveryPlan(records: updated, commands: commands)
    }

    public static func facts(db: DatabasePool) async throws -> (running: Set<String>, present: Set<String>) {
        try await db.read { database in
            let rows = try Row.fetchAll(database, sql: "SELECT id, state FROM vms")
            var running = Set<String>()
            var present = Set<String>()
            for row in rows {
                let id: String = row["id"]
                let state: String = row["state"]
                present.insert(id)
                if state == "running" {
                    running.insert(id)
                }
            }
            return (running, present)
        }
    }

    public static func preservedVolumes(_ paths: [String]) -> [String] {
        paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    private static func command(_ record: DurableWorkloadOperation) -> WorkloadSocketCommand {
        WorkloadSocketCommand(
            operationID: record.operationID,
            workloadID: record.workloadID,
            kind: record.kind,
        )
    }
}

public struct HostRollbackConfirmation: Equatable, Sendable {
    public var operationID: String
    public var target: String

    public init(operationID: String, target: String) {
        self.operationID = operationID
        self.target = target
    }
}

public enum HostNetworkDaemonRollback {
    public static func rollbackWhileServerDown(
        pending: HostNetworkPendingCommit,
        serverAvailable: Bool,
        requestedOperationID: String,
        revert: (HostNetworkPendingCommit) throws -> Void,
    ) throws -> HostRollbackConfirmation {
        if serverAvailable {
            throw LocalManagementError.malformed
        }
        guard let operationID = pending.operationID, operationID == requestedOperationID else {
            throw LocalManagementError.malformed
        }
        try revert(pending)
        return HostRollbackConfirmation(operationID: operationID, target: pending.target)
    }
}
