import BarkVisorCore
import Foundation
import Vapor

/// Home WebSocket tunnel for member VNC / serial console (PAS-200).
///
/// Registered on the JWT group. StreamTicketPolicy: Bearer or Home `?session=`;
/// Device `?ticket=` is forwarded unspent.
struct HomeConsoleProxyController {
    var devices: DeviceRegistry?
    var dataDir: URL
    var hostId: String
    var localPort: Int
    var dialer: any HomeWebSocketDialing

    init(
        dataDir: URL = Config.dataDir,
        hostId: String = Config.hostId,
        localPort: Int = Config.port,
        devices: DeviceRegistry? = nil,
        dialer: (any HomeWebSocketDialing)? = nil,
    ) {
        self.dataDir = dataDir
        self.hostId = hostId
        self.localPort = localPort
        self.devices = devices
        self.dialer = dialer ?? HomeWebSocketDialer(dataDir: dataDir, hostId: hostId)
    }

    func register(app: any RoutesBuilder) {
        register(app: app, kind: .vnc)
        register(app: app, kind: .console)
    }

    private func register(app: any RoutesBuilder, kind: HomeConsoleKind) {
        app.webSocket(
            "api", "home", "devices", ":id", "v1", "vms", ":vmId", .constant(kind.rawValue),
            shouldUpgrade: { req in
                _ = try req.requireUser
                try HomeConsoleProxy.requireTicket(req)
                _ = try self.targetURL(req: req, kind: kind)
                return [:]
            },
            onUpgrade: { req, ws in
                // Do not await on inbound.eventLoop — the outbound
                // WebSocket.connect needs that loop to complete.
                Task {
                    await self.tunnel(req: req, inbound: ws, kind: kind)
                }
            },
        )
    }

    func targetURL(req: Vapor.Request, kind: HomeConsoleKind) throws -> URL {
        let id = try req.parameters.require("id")
        let vmID = try req.parameters.require("vmId")
        if id == hostId {
            return try HomeDeviceProxy.consoleTargetURL(
                HomeConsoleTarget(
                    isSelf: true,
                    localPort: localPort,
                    agentHost: nil,
                    agentPort: localPort,
                    vmID: vmID,
                    kind: kind,
                    query: req.url.query,
                ),
            )
        }
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        let record: DeviceRecord
        do {
            guard let found = try store.record(forHostId: id) else {
                throw BarkVisorError.notFound("Device not found")
            }
            record = found
        } catch let error as BarkVisorError {
            throw error
        } catch {
            throw Abort(
                .serviceUnavailable,
                reason: "Device registry is unavailable; local runtime continues",
            )
        }
        guard let agentHost = record.agentHost, !agentHost.isEmpty else {
            throw Abort(.serviceUnavailable, reason: "Device has no reachable address")
        }
        return try HomeDeviceProxy.consoleTargetURL(
            HomeConsoleTarget(
                isSelf: false,
                localPort: localPort,
                agentHost: agentHost,
                agentPort: record.agentPort,
                vmID: vmID,
                kind: kind,
                query: req.url.query,
            ),
        )
    }

    private func tunnel(req: Vapor.Request, inbound: WebSocket, kind: HomeConsoleKind) async {
        let url: URL
        do {
            url = try targetURL(req: req, kind: kind)
        } catch {
            WebSocketRelay.close(inbound)
            return
        }
        await WebSocketHop.run(inbound: inbound, url: url, dialer: dialer)
    }
}

enum HomeConsoleProxy {
    /// Presence + UUID shape. Spend is StreamTicketPolicy on the owner Device.
    static func requireTicket(_ req: Vapor.Request) throws {
        let ticket = StreamTicketPolicy.deviceTicket(fromQuery: req.url.query)
            ?? req.query[String.self, at: StreamTicketPolicy.ticketQueryName]
            ?? req.query[String.self, at: StreamTicketPolicy.tokenRewriteQueryName]
        do {
            try StreamTicketPolicy.requirePassThroughDeviceTicket(ticket)
        } catch let error as BarkVisorError {
            throw Abort(.unauthorized, reason: error.errorDescription ?? "Unauthorized")
        }
    }

    /// HTTP catch-all must not wrap an Upgrade. The dedicated tunnel owns these.
    static func rejectStrippedUpgrade(_ req: Vapor.Request) throws {
        let upgrade = req.headers[canonicalForm: "upgrade"].joined(separator: ",")
        let connection = req.headers[canonicalForm: "connection"].joined(separator: ",")
        if upgrade.localizedCaseInsensitiveContains("websocket")
            || connection.localizedCaseInsensitiveContains("upgrade") {
            throw Abort(
                .upgradeRequired,
                reason: "Console and VNC require the WebSocket tunnel, not the HTTP proxy",
            )
        }
    }
}
