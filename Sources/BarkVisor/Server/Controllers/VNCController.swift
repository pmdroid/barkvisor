import BarkVisorCore
import Foundation
import JWTKit
import NIOCore
import NIOPosix
import Vapor

/// Thread-safe box for the VNC TCP channel reference
private final class ChannelBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _channel: Channel?
    private var _pending: [ByteBuffer] = []

    var channel: Channel? {
        lock.lock()
        defer { lock.unlock() }
        return _channel
    }

    func set(_ channel: Channel) {
        let buffered: [ByteBuffer] = {
            lock.lock()
            defer { lock.unlock() }
            _channel = channel
            let b = _pending
            _pending.removeAll()
            return b
        }()

        // Flush buffered frames
        for buf in buffered {
            var copy = channel.allocator.buffer(capacity: buf.readableBytes)
            copy.writeBytes(buf.readableBytesView)
            channel.writeAndFlush(copy, promise: nil)
        }
    }

    func sendOrBuffer(_ buf: ByteBuffer) {
        let channel: Channel? = {
            lock.lock()
            defer { lock.unlock() }
            if let ch = _channel {
                return ch
            } else {
                _pending.append(buf)
                return nil
            }
        }()

        if let channel {
            var copy = channel.allocator.buffer(capacity: buf.readableBytes)
            copy.writeBytes(buf.readableBytesView)
            channel.writeAndFlush(copy, promise: nil)
        }
    }
}

struct VNCController {
    let vmState: any VMStateQuerying
    let keys: JWTKeyCollection

    func register(app: Vapor.Application) {
        app.webSocket(
            "api", "vms", ":id", "vnc",
            shouldUpgrade: { req in
                guard let vmID = req.parameters.get("id") else {
                    throw Abort(.badRequest)
                }
                // noVNC's RFB client rewrites ?ticket= to ?token= internally
                guard let ticket = req.query[String.self, at: "ticket"] ?? req.query[String.self, at: "token"]
                else {
                    throw Abort(
                        .unauthorized, reason: "Missing ticket. Use POST /api/auth/ws-ticket to obtain one.",
                    )
                }
                guard await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: vmID) != nil else {
                    throw Abort(.unauthorized, reason: "Invalid or expired ticket")
                }
                return [:]
            },
            onUpgrade: { req, ws in
                let vmState = vmState
                let eventLoop = req.eventLoop
                let box = ChannelBox()

                // Register WS handlers on the event loop (required by NIOLoopBound)
                eventLoop.execute {
                    ws.onBinary { _, buf in
                        box.sendOrBuffer(buf)
                    }
                }

                Task {
                    guard let vmID = req.parameters.get("id") else {
                        eventLoop.execute { ws.close(code: .policyViolation, promise: nil) }
                        return
                    }

                    guard let vncSocketPath = await vmState.vncSocketPath(for: vmID) else {
                        let isRunning = await vmState.isRunning(vmID)
                        Log.vm.error(
                            "VNC WebSocket closed: no socket path for VM \(vmID) (isRunning=\(isRunning))",
                            vm: vmID,
                        )
                        eventLoop.execute { ws.close(code: .normalClosure, promise: nil) }
                        return
                    }

                    do {
                        let channel = try await ClientBootstrap(group: eventLoop)
                            .channelInitializer { channel in
                                channel.pipeline.addHandler(SocketToWSHandler(ws: ws))
                            }
                            .connect(unixDomainSocketPath: vncSocketPath)
                            .get()

                        box.set(channel)

                        ws.onClose.whenComplete { _ in
                            channel.close(mode: .all, promise: nil)
                        }
                    } catch {
                        Log.vm.error(
                            "VNC connection failed for VM \(vmID) at \(vncSocketPath): \(error)", vm: vmID,
                        )
                        eventLoop.execute { ws.close(code: .unexpectedServerError, promise: nil) }
                    }
                }
            },
        )
    }
}
