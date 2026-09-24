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
    private var operations: [String: StoredOperation] = [:]
    private var decisionLog: [AuthorizationDecision] = []
    private var effects = 0
    private var bufferedEventBytes = 0

    public init(policy: LocalManagementPolicy) {
        self.policy = policy
    }

    public func handle(
        peer: LocalPeerIdentity,
        request: LocalManagementRequest,
    ) -> LocalManagementResponse {
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
            return query(request, subject: decision.subject ?? "")
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

    private func query(
        _ request: LocalManagementRequest,
        subject: String,
    ) -> LocalManagementResponse {
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
