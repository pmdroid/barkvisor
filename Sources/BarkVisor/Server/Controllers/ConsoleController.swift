import BarkVisorCore
import Foundation
import JWTKit
import NIOCore
import NIOPosix
import Vapor

struct ConsoleController {
    let vmState: any VMStateQuerying
    let consoleBuffers: ConsoleBufferManager
    let keys: JWTKeyCollection

    func register(app: Vapor.Application) {
        app.webSocket(
            "api", "vms", ":id", "console",
            shouldUpgrade: { req in
                guard let vmID = req.parameters.get("id") else {
                    throw Abort(.badRequest)
                }
                guard let ticket = req.query[String.self, at: "ticket"] else {
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
                let buffers = consoleBuffers
                let eventLoop = req.eventLoop

                Task {
                    guard let vmID = req.parameters.get("id"),
                          UUID(uuidString: vmID) != nil
                    else {
                        eventLoop.execute { ws.close(code: .policyViolation, promise: nil) }
                        return
                    }

                    guard await vmState.isRunning(vmID) else {
                        let hasSocket = await vmState.serialSocketPath(for: vmID)
                        Log.vm.debug(
                            "Console WebSocket closed: VM \(vmID) not in runningVMs (hasSocket=\(hasSocket != nil))",
                            vm: vmID,
                        )
                        eventLoop.execute {
                            ws.send("VM is not running\r\n", promise: nil)
                            ws.close(code: .normalClosure, promise: nil)
                        }
                        return
                    }

                    // Replay scrollback history
                    let scrollback = await buffers.scrollback(vmID: vmID)
                    if !scrollback.isEmpty {
                        eventLoop.execute {
                            ws.send(Array(scrollback), promise: nil)
                        }
                    }

                    // Register as live listener
                    let listenerId = UUID().uuidString
                    await buffers.addListener(vmID: vmID, id: listenerId) { bytes in
                        eventLoop.execute {
                            ws.send(bytes, promise: nil)
                        }
                    }

                    // WebSocket input → serial socket
                    eventLoop.execute {
                        ws.onText { _, text in
                            if let data = text.data(using: .utf8) {
                                Task { await buffers.write(vmID: vmID, data: data) }
                            }
                        }

                        ws.onBinary { _, buf in
                            let data = Data(buf.readableBytesView)
                            Task { await buffers.write(vmID: vmID, data: data) }
                        }

                        ws.onClose.whenComplete { _ in
                            Task { await buffers.removeListener(vmID: vmID, id: listenerId) }
                        }
                    }
                }
            },
        )
    }
}
