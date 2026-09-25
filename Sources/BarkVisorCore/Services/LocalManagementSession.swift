import Foundation

public struct StoredOperation: Equatable, Sendable {
    public var operationId: String
    public var subject: String
    public var phase: String
    public var effectCount: Int
    public var marker: String?

    public init(
        operationId: String,
        subject: String,
        phase: String,
        effectCount: Int,
        marker: String?,
    ) {
        self.operationId = operationId
        self.subject = subject
        self.phase = phase
        self.effectCount = effectCount
        self.marker = marker
    }
}

public actor LocalManagementSession {
    private let policy: LocalManagementPolicy
    private let operationStore: (any DurableOperationStoring)?
    private let workloadDriver: (any WorkloadSocketDriving)?
    private var operations: [String: StoredOperation] = [:]
    private var decisionLog: [AuthorizationDecision] = []
    private var effects = 0
    private var bufferedEventBytes = 0
    private var sequence = 0
    private var inFlight: Set<String> = []

    public init(
        policy: LocalManagementPolicy,
        operationStore: (any DurableOperationStoring)? = nil,
        workloadDriver: (any WorkloadSocketDriving)? = nil,
    ) {
        self.policy = policy
        self.operationStore = operationStore
        self.workloadDriver = workloadDriver
    }

    public func handle(
        peer: LocalPeerIdentity,
        request: LocalManagementRequest,
    ) async -> LocalManagementResponse {
        let decision = LocalManagementAuthorization.decide(
            peer: peer,
            request: request,
            policy: policy,
        )
        decisionLog.append(decision)
        guard decision.allowed else {
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: false,
                phase: "rejected",
                effectCount: 0,
                rejection: decision.reason,
            )
        }
        if request.name == "protocolVersion" {
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: true,
                phase: "completed",
                effectCount: 0,
                marker: String(LocalManagementLimits.version),
            )
        }
        if request.name == "query" {
            return await query(request, subject: decision.subject ?? "")
        }
        if WorkloadSocketOperations.names.contains(request.name) {
            return await workload(request, subject: decision.subject ?? "")
        }
        guard request.name == "applyMarker" || request.name == "validateResources"
            || request.name == "openTerminal"
        else {
            return LocalManagementResponse.rejection(request: request, reason: .unknownOperation)
        }
        return accept(request, subject: decision.subject ?? "")
    }

    public func effectCount() -> Int {
        effects
    }

    public func recordedDecisions() -> [AuthorizationDecision] {
        decisionLog
    }

    public func noteEvent(bytes: Int) -> LocalRejection? {
        if bytes <= 0 || bufferedEventBytes > policy.maxEventBytes - bytes {
            return .slowConsumer
        }
        bufferedEventBytes += bytes
        return nil
    }

    public func bufferedEvents() -> Int {
        bufferedEventBytes
    }

    private func workload(
        _ request: LocalManagementRequest,
        subject: String,
    ) async -> LocalManagementResponse {
        guard let workloadID = request.workloadID else {
            return LocalManagementResponse.rejection(request: request, reason: .invalidPath)
        }
        if request.name == "workload.status" || request.name == "workload.events" {
            return await readWorkload(request, workloadID: workloadID)
        }
        guard let kind = WorkloadSocketOperations.kind(for: request.name) else {
            return LocalManagementResponse.rejection(request: request, reason: .unknownOperation)
        }
        if let existing = await operationStore?.find(operationID: request.operationId) {
            guard existing.subject == subject else {
                return LocalManagementResponse.rejection(request: request, reason: .operationNotVisible)
            }
            return WorkloadSocketOperations.response(request: request, record: existing, events: existing.events)
        }
        if inFlight.contains(request.operationId) {
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: true,
                phase: "accepted",
                effectCount: 0,
                subject: subject,
                workloadID: workloadID,
                workloadState: "accepted",
            )
        }
        guard let workloadDriver else {
            return LocalManagementResponse.rejection(request: request, reason: .unknownOperation)
        }
        inFlight.insert(request.operationId)
        sequence += 1
        let reservedSequence = sequence
        let accepted = DurableWorkloadOperation(
            operationID: request.operationId,
            workloadID: workloadID,
            subject: subject,
            kind: kind,
            phase: "accepted",
            state: "accepted",
            runtime: "",
            events: [],
            sequence: reservedSequence,
        )
        await operationStore?.save(accepted)
        let command = WorkloadSocketCommand(
            operationID: request.operationId,
            workloadID: workloadID,
            kind: kind,
        )
        do {
            let snapshot = try await workloadDriver.perform(command)
            effects += 1
            let event = "\(kind) \(workloadID) \(snapshot.state) \(snapshot.runtime)"
            let completed = DurableWorkloadOperation(
                operationID: request.operationId,
                workloadID: workloadID,
                subject: subject,
                kind: kind,
                phase: "completed",
                state: snapshot.state,
                runtime: snapshot.runtime,
                events: [event],
                sequence: reservedSequence,
            )
            inFlight.remove(request.operationId)
            await operationStore?.save(completed)
            return WorkloadSocketOperations.response(
                request: request,
                record: completed,
                events: completed.events,
            )
        } catch {
            let failed = DurableWorkloadOperation(
                operationID: request.operationId,
                workloadID: workloadID,
                subject: subject,
                kind: kind,
                phase: "failed",
                state: "failed",
                runtime: "",
                events: [error.localizedDescription],
                sequence: reservedSequence,
            )
            inFlight.remove(request.operationId)
            await operationStore?.save(failed)
            return WorkloadSocketOperations.response(request: request, record: failed, events: failed.events)
        }
    }

    private func readWorkload(
        _ request: LocalManagementRequest,
        workloadID: String,
    ) async -> LocalManagementResponse {
        guard let record = await operationStore?.latest(workloadID: workloadID) else {
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: false,
                phase: "absent",
                effectCount: 0,
                workloadID: workloadID,
            )
        }
        let events = request.name == "workload.events" ? record.events : nil
        if let events {
            let bytes = events.joined(separator: "\n").utf8.count
            if noteEvent(bytes: bytes) != nil {
                return LocalManagementResponse.rejection(request: request, reason: .slowConsumer)
            }
        }
        return WorkloadSocketOperations.response(request: request, record: record, events: events)
    }

    private func query(
        _ request: LocalManagementRequest,
        subject: String,
    ) async -> LocalManagementResponse {
        if let durable = await operationStore?.find(operationID: request.operationId) {
            guard durable.subject == subject else {
                return LocalManagementResponse.rejection(request: request, reason: .operationNotVisible)
            }
            return WorkloadSocketOperations.response(
                request: request,
                record: durable,
                events: durable.events,
            )
        }
        guard let stored = operations[request.operationId] else {
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: false,
                phase: "absent",
                effectCount: 0,
            )
        }
        guard stored.subject == subject else {
            return LocalManagementResponse.rejection(request: request, reason: .operationNotVisible)
        }
        return LocalManagementResponse(
            requestId: request.requestId,
            operationId: stored.operationId,
            accepted: true,
            phase: stored.phase,
            effectCount: stored.effectCount,
            subject: stored.subject,
            marker: stored.marker,
        )
    }

    private func accept(
        _ request: LocalManagementRequest,
        subject: String,
    ) -> LocalManagementResponse {
        if let stored = operations[request.operationId] {
            guard stored.subject == subject else {
                return LocalManagementResponse.rejection(
                    request: request,
                    reason: .operationNotVisible,
                )
            }
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: stored.operationId,
                accepted: true,
                phase: stored.phase,
                effectCount: stored.effectCount,
                subject: stored.subject,
                marker: stored.marker,
            )
        }
        effects += 1
        let stored = StoredOperation(
            operationId: request.operationId,
            subject: subject,
            phase: "completed",
            effectCount: effects,
            marker: request.marker,
        )
        operations[request.operationId] = stored
        return LocalManagementResponse(
            requestId: request.requestId,
            operationId: stored.operationId,
            accepted: true,
            phase: stored.phase,
            effectCount: stored.effectCount,
            subject: stored.subject,
            marker: stored.marker,
        )
    }
}

public enum LocalManagementClient {
    public static func submit(
        _ request: LocalManagementRequest,
        exchange: (LocalManagementRequest) throws -> LocalManagementResponse,
    ) throws -> LocalManagementResponse {
        do {
            return try exchange(request)
        } catch LocalManagementError.connectionLost {
            var query = request
            query.name = "query"
            query.marker = nil
            let existing = try exchange(query)
            if existing.phase == "absent" {
                return try exchange(request)
            }
            return existing
        }
    }
}
