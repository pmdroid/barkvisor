import BarkVisorCore
import Foundation
import NIOCore
import NIOSSL
import Vapor

/// Bidirectional WebSocket pipe for Home → member console tunnels (PAS-200).
///
/// Inbound frames are buffered until the outbound socket is attached so a
/// client that sends immediately after 101 is not dropped.
final class WebSocketPipeBox: @unchecked Sendable {
    enum Frame {
        case binary(ByteBuffer)
        case text(String)
    }

    static let defaultMaxPendingBytes = 262_144

    private let lock = NSLock()
    private var remote: WebSocket?
    private var pending: [Frame] = []
    private var pendingBytes = 0
    var maxPendingBytes = WebSocketPipeBox.defaultMaxPendingBytes
    private(set) var overflowed = false

    func attach(_ ws: WebSocket) {
        let buffered: [Frame] = {
            lock.lock()
            defer { lock.unlock() }
            remote = ws
            let frames = pending
            pending.removeAll()
            return frames
        }()
        for frame in buffered {
            WebSocketRelay.send(frame, on: ws)
        }
    }

    func sendOrBuffer(_ frame: Frame) -> Bool {
        let outcome: (WebSocket?, Bool) = {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return (nil, false) }
            if let remote {
                return (remote, true)
            }
            let size = Self.byteCount(frame)
            if pendingBytes + size > maxPendingBytes {
                overflowed = true
                pending.removeAll()
                pendingBytes = 0
                return (nil, false)
            }
            pending.append(frame)
            pendingBytes += size
            return (nil, true)
        }()
        if let ws = outcome.0 {
            WebSocketRelay.send(frame, on: ws)
        }
        return outcome.1
    }

    private static func byteCount(_ frame: Frame) -> Int {
        switch frame {
        case let .binary(buffer): buffer.readableBytes
        case let .text(text): text.utf8.count
        }
    }
}

enum WebSocketRelay {
    static func pipe(local: WebSocket, remote: WebSocket) {
        bindCloses(local: local, remote: remote)
    }

    /// Install receive handlers. Call this inside `WebSocket.connect` so
    /// server-first frames (RFB banner, serial scrollback) are not dropped.
    static func capture(from ws: WebSocket, into box: WebSocketPipeBox) {
        ws.onBinary { inbound, buffer in
            if !box.sendOrBuffer(.binary(buffer)) {
                close(inbound)
            }
        }
        ws.onText { inbound, text in
            if !box.sendOrBuffer(.text(text)) {
                close(inbound)
            }
        }
    }

    static func bindCloses(local: WebSocket, remote: WebSocket) {
        local.onClose.whenComplete { _ in
            close(remote)
        }
        remote.onClose.whenComplete { _ in
            close(local)
        }
    }

    static func send(_ frame: WebSocketPipeBox.Frame, on ws: WebSocket) {
        onEventLoop(ws) {
            guard !ws.isClosed else { return }
            switch frame {
            case let .binary(buffer):
                ws.send(raw: buffer.readableBytesView, opcode: .binary, fin: true, promise: nil)
            case let .text(text):
                ws.send(text)
            }
        }
    }

    static func close(_ ws: WebSocket) {
        onEventLoop(ws) {
            if !ws.isClosed {
                ws.close(promise: nil)
            }
        }
    }

    static func onEventLoop(_ ws: WebSocket, _ body: @escaping @Sendable () -> Void) {
        if ws.eventLoop.inEventLoop {
            body()
        } else {
            ws.eventLoop.execute(body)
        }
    }
}

private final class OnceResume<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        continuation.resume(with: result)
        return true
    }
}

/// Closes a late handshake if the 10s dial already failed.
private final class DialLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var open: WebSocket?

    func accept(_ ws: WebSocket) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        open = ws
        return true
    }

    func cancel() {
        let extra: WebSocket?
        lock.lock()
        cancelled = true
        extra = open
        open = nil
        lock.unlock()
        if let extra {
            WebSocketRelay.close(extra)
        }
    }
}

protocol HomeWebSocketDialing: Sendable {
    func connect(
        url: URL,
        on eventLoop: EventLoop,
        configure: @escaping @Sendable (WebSocket) -> Void,
    ) async throws -> WebSocket
}

/// Outbound WebSocket client. `ws://` is loopback (This Device / agent hop).
/// `wss://` uses the same mTLS material as the Home HTTP proxy.
struct HomeWebSocketDialer: HomeWebSocketDialing {
    var dataDir: URL
    var hostId: String

    static let dialTimeoutNanoseconds: UInt64 = 10_000_000_000

    func connect(
        url: URL,
        on eventLoop: EventLoop,
        configure: @escaping @Sendable (WebSocket) -> Void,
    ) async throws -> WebSocket {
        var configuration = WebSocketClient.Configuration()
        if url.scheme?.lowercased() == "wss" {
            configuration.tlsConfiguration = try Self.mtlsConfiguration(
                dataDir: dataDir,
                hostId: hostId,
            )
        }
        return try await Self.open(
            url: url,
            configuration: configuration,
            on: eventLoop,
            configure: configure,
        )
    }

    static func open(
        url: URL,
        configuration: WebSocketClient.Configuration = .init(),
        on eventLoop: EventLoop,
        configure: @escaping @Sendable (WebSocket) -> Void = { _ in },
    ) async throws -> WebSocket {
        let lifetime = DialLifetime()
        do {
            return try await withThrowingTaskGroup(of: WebSocket.self) { group in
                group.addTask {
                    try await connectOnce(
                        url: url,
                        configuration: configuration,
                        on: eventLoop,
                        lifetime: lifetime,
                        configure: configure,
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: dialTimeoutNanoseconds)
                    throw Abort(.gatewayTimeout, reason: "Device console did not answer")
                }
                let socket = try await group.next()!
                group.cancelAll()
                return socket
            }
        } catch {
            lifetime.cancel()
            throw error
        }
    }

    private static func connectOnce(
        url: URL,
        configuration: WebSocketClient.Configuration,
        on eventLoop: EventLoop,
        lifetime: DialLifetime,
        configure: @escaping @Sendable (WebSocket) -> Void,
    ) async throws -> WebSocket {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WebSocket, Error>) in
            let once = OnceResume(cont)
            let future = WebSocket.connect(
                to: url.absoluteString,
                configuration: configuration,
                on: eventLoop,
            ) { ws in
                if lifetime.accept(ws) {
                    configure(ws)
                    _ = once.resume(.success(ws))
                } else {
                    WebSocketRelay.close(ws)
                    _ = once.resume(.failure(CancellationError()))
                }
            }
            future.whenFailure { error in
                _ = once.resume(.failure(error))
            }
        }
    }

    static func mtlsConfiguration(dataDir: URL, hostId: String) throws -> TLSConfiguration {
        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
        let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
        let presented = AgentPlaneCertificates.presentationCertificatePEM(
            material: material,
            receipt: receipt,
        )
        let trusts = AgentPlaneCertificates.trustCertificatePEMs(
            material: material,
            receipt: receipt,
        )
        let roots = try trusts.map { pem in
            try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
        }
        let cert = try NIOSSLCertificate(bytes: Array(presented.utf8), format: .pem)
        let key = try NIOSSLPrivateKey(bytes: Array(material.deviceKeyPEM.utf8), format: .pem)
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .noHostnameVerification
        tls.trustRoots = .certificates(roots)
        tls.certificateChain = [.certificate(cert)]
        tls.privateKey = .privateKey(key)
        tls.minimumTLSVersion = .tlsv12
        return tls
    }
}
