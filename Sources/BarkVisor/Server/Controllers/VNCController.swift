import BarkVisorCore
import Foundation
import JWTKit
import Vapor

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

                    await WebSocketHop.run(inbound: ws, unixSocketPath: vncSocketPath)
                }
            },
        )
    }
}
