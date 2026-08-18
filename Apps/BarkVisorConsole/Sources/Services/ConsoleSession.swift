import Foundation

/// Native serial console: mint a one-use ticket, then `URLSessionWebSocketTask`.
/// This Device uses `/api/vms/{id}/console?ticket=`. A member uses the Home
/// tunnel (`/api/home/devices/{id}/v1/vms/{id}/console?ticket=&session=`).
/// The session JWT is never placed on the WebSocket URL.
@Observable
@MainActor
final class ConsoleSession {
    var status = ""

    private var client: APIClient?
    private var workloadID = ""
    private var device: HomeDeviceHealthSnapshot?
    private var state = ""
    private var stopped = true
    private var attempt = 0
    private var socket: URLSessionWebSocketTask?
    private var loop: Task<Void, Never>?
    private let urlSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = nil
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// Terminal feed hook so UI tests do not need SwiftTerm.
    var onBytes: ((ArraySlice<UInt8>) -> Void)?
    var onText: ((String) -> Void)?

    func start(
        client: APIClient,
        workloadID: String,
        state: String,
        device: HomeDeviceHealthSnapshot? = nil,
    ) {
        stop()
        self.client = client
        self.workloadID = workloadID
        self.device = device
        self.state = state
        stopped = false
        attempt = 0
        loop = Task { await run() }
    }

    func updateState(_ state: String) {
        self.state = state
        if !WorkloadStream.isLive(state) {
            loop?.cancel()
            loop = nil
            closeSocket()
            status = WorkloadStreamAccess.notLive.reason
        }
    }

    /// Ticket may be used only while this session is still the live stream.
    func canOpenStream() -> Bool {
        !stopped && WorkloadStream.isLive(state)
    }

    /// Test seam: apply a live/not-live state without opening a socket.
    func primeForTest(state: String) {
        self.state = state
        stopped = false
    }

    func stop() {
        stopped = true
        loop?.cancel()
        loop = nil
        closeSocket()
    }

    func send(_ data: ArraySlice<UInt8>) {
        guard let socket else { return }
        socket.send(.data(Data(data))) { _ in }
    }

    private func closeSocket() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func run() async {
        while !stopped, !Task.isCancelled {
            guard WorkloadStream.isLive(state) else {
                status = WorkloadStreamAccess.notLive.reason
                return
            }
            guard let client else { return }
            do {
                status = "Requesting ticket…"
                let tickets = try await client.mintStreamTickets(vmID: workloadID, on: device)
                guard canOpenStream(), !Task.isCancelled else {
                    if !WorkloadStream.isLive(state) {
                        status = WorkloadStreamAccess.notLive.reason
                    }
                    return
                }
                let url = try StreamURL.console(
                    base: client.baseURL,
                    workloadID: workloadID,
                    ticket: tickets.ticket,
                    device: device,
                    session: tickets.session,
                )
                status = "Connecting…"
                let task = urlSession.webSocketTask(with: url)
                socket = task
                task.resume()
                status = ""
                if await receive(task) {
                    attempt = 0
                }
            } catch is CancellationError {
                return
            } catch {
                status = error.localizedDescription
            }
            // Cancel the finished task so reconnect does not leave a live socket.
            closeSocket()
            guard !stopped, !Task.isCancelled else { return }
            guard WorkloadStream.isLive(state) else {
                status = WorkloadStreamAccess.notLive.reason
                return
            }
            attempt += 1
            guard StreamReconnect.shouldRetry(attempt: attempt) else {
                status = "Disconnected — max reconnect attempts reached"
                return
            }
            status = "Disconnected, reconnecting (\(attempt)/\(StreamReconnect.maxAttempts))…"
            try? await Task.sleep(nanoseconds: StreamReconnect.delayNanoseconds(attempt: attempt))
        }
    }

    /// Returns true after at least one payload arrived, so a socket that
    /// accepts and immediately closes does not reset the reconnect budget.
    private func receive(_ task: URLSessionWebSocketTask) async -> Bool {
        var received = false
        while !stopped, !Task.isCancelled, socket === task {
            do {
                let message = try await task.receive()
                received = true
                switch message {
                case let .data(data):
                    onBytes?(Array(data)[...])
                case let .string(text):
                    onText?(text)
                @unknown default:
                    break
                }
            } catch {
                return received
            }
        }
        return received
    }
}
