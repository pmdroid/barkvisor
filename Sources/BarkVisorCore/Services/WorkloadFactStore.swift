import Foundation
import GRDB

public enum WorkloadFactStore {
    public static func commitConfiguration(
        db: Database,
        id: String,
        expectedGeneration: Int,
        mutate: (inout VM) throws -> Void,
    ) throws -> VM {
        guard var current = try VM.fetchOne(db, key: id) else {
            throw BarkVisorError.notFound("Workload not found")
        }
        if current.specGeneration != expectedGeneration {
            throw BarkVisorError.conflict(
                "configuration generation \(current.specGeneration) is newer than \(expectedGeneration)",
            )
        }
        let before = current
        try mutate(&current)
        if current.specGeneration < before.specGeneration {
            throw BarkVisorError.conflict("configuration generation cannot move backwards")
        }
        try current.update(db)
        return current
    }

    public static func recordObservation(
        db: Database,
        workloadId: String,
        appliedGeneration: Int,
        runtimeIdentity: String?,
        processState: String,
        readiness: String,
        condition: String,
        observedAt: String,
        error: String?,
        freshness: String,
        enforcedCpu: Int?,
        enforcedMemoryMb: Int?,
        services: [WorkloadServiceObservation]? = nil,
        basedOnSequence: Int? = nil,
    ) throws -> WorkloadObservation {
        let existing = try WorkloadObservation.fetchOne(db, key: workloadId)
        if let existing, appliedGeneration < existing.appliedGeneration {
            throw BarkVisorError.conflict(
                "applied generation \(existing.appliedGeneration) is newer than \(appliedGeneration)",
            )
        }
        if let basedOnSequence, let existing, basedOnSequence != existing.sequence {
            throw BarkVisorError.conflict(
                "observation sequence \(existing.sequence) is newer than \(basedOnSequence)",
            )
        }
        let row = WorkloadObservation(
            id: workloadId,
            sequence: (existing?.sequence ?? 0) + 1,
            appliedGeneration: appliedGeneration,
            runtimeIdentity: runtimeIdentity,
            processState: processState,
            readiness: readiness,
            condition: condition,
            observedAt: observedAt,
            error: error,
            freshness: freshness,
            enforcedCpu: enforcedCpu ?? existing?.enforcedCpu,
            enforcedMemoryMb: enforcedMemoryMb ?? existing?.enforcedMemoryMb,
            servicesJson: services.flatMap(WorkloadObservation.encodeServices) ?? existing?.servicesJson,
        )
        if existing == nil {
            try row.insert(db)
        } else {
            try row.update(db)
        }
        return row
    }

    public static func mergingRuntimeSnapshot(current: VM, snapshot: VM) -> VM? {
        guard snapshot.specGeneration == current.specGeneration else { return nil }
        var next = current
        next.state = snapshot.state
        next.updatedAt = snapshot.updatedAt
        next.imageRef = snapshot.imageRef
        next.digest = snapshot.digest
        next.catalogDigest = snapshot.catalogDigest
        next.volumeRootsJson = snapshot.volumeRootsJson
        next.portForwards = snapshot.portForwards
        next.runtimeWorkloadId = snapshot.runtimeWorkloadId
        next.runtime = snapshot.runtime
        return next
    }

    public static func disconnect(_ view: WorkloadDeliveredView) -> WorkloadDeliveredView {
        var stale = view
        stale.freshness = "stale"
        return stale
    }

    public static func reconnect(authoritative: WorkloadDeliveredView) -> WorkloadDeliveredView {
        authoritative
    }

    public static func applyDeliveredView(_ view: WorkloadDeliveredView, db: Database) throws {
        _ = view
        _ = db
        throw BarkVisorError.conflict(
            "delivered view cannot overwrite configuration or applied generation",
        )
    }

    public static func projection(
        vm: VM,
        observation: WorkloadObservation?,
    ) -> WorkloadDeliveredView {
        WorkloadDeliveredView(
            id: vm.id,
            configurationGeneration: vm.specGeneration,
            appliedGeneration: observation?.appliedGeneration ?? 0,
            processState: observation?.processState ?? vm.state,
            readiness: observation?.readiness ?? "unknown",
            condition: observation?.condition ?? "unknown",
            freshness: observation?.freshness ?? "unknown",
            observedAt: observation?.observedAt,
            error: observation?.error,
        )
    }
}
