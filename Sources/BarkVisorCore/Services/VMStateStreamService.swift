import Foundation

public actor VMStateStreamService {
    private var stateContinuations: [String: [UUID: AsyncStream<VMStateEvent>.Continuation]] = [:]

    public init() {}

    // MARK: - SSE State Stream

    public func stateStream(vmID: String) -> AsyncStream<VMStateEvent> {
        let contID = UUID()
        return AsyncStream { continuation in
            stateContinuations[vmID, default: [:]][contID] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(vmID: vmID, id: contID) }
            }
        }
    }

    private func removeContinuation(vmID: String, id: UUID) {
        stateContinuations[vmID]?.removeValue(forKey: id)
        if stateContinuations[vmID]?.isEmpty == true {
            stateContinuations.removeValue(forKey: vmID)
        }
    }

    /// Yield an event to all SSE listeners for the given VM.
    public func broadcast(event: VMStateEvent) {
        if let conts = stateContinuations[event.id] {
            for cont in conts.values {
                cont.yield(event)
            }
        }
    }
}
