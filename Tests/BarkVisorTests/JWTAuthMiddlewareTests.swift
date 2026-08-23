import Foundation
import JWTKit
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

private struct OKResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}

@Suite("JWTAuthMiddleware ticket scope (PAS-280)", .serialized)
struct JWTAuthMiddlewareTests {
    private func makeApp() async throws -> Application {
        var env = Environment(name: "testing", arguments: ["barkvisor-test"])
        env.commandInput = CommandInput(arguments: ["barkvisor-test"])
        let app = try await Application.make(env)
        app.logger.logLevel = .error
        return app
    }

    private func stop(_ app: Application) async {
        try? await app.asyncShutdown()
    }

    private func makeKeys() async -> JWTKeyCollection {
        let keys = JWTKeyCollection()
        await keys.add(hmac: .init(from: "pas-280-test-secret"), digestAlgorithm: .sha256)
        return keys
    }

    private func request(_ app: Application, path: String) -> Request {
        Request(
            application: app,
            method: .GET,
            url: URI(string: path),
            on: app.eventLoopGroup.next(),
        )
    }

    private func mintTicket(vmID: String? = "vm-1") async -> String {
        await WebSocketTicketStore.shared.createTicket(
            forUserID: "user-1", username: "admin", targetVMID: vmID,
        )
    }

    @Test func `control plane ignores unscoped ticket and does not spend it`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket()
        do {
            let req = request(app, path: "/api/vms/vm-1/start?ticket=\(ticket)")
            do {
                _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                Issue.record("expected unauthorized without Bearer")
            } catch let error as AbortError {
                #expect(error.status == .unauthorized)
            }
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-1")
            #expect(leftover?.userID == "user-1", "control-plane ?ticket= must not spend the ticket")
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `stray ticket on control plane still allows Bearer JWT`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket()
        let payload = UserPayload(
            sub: .init(value: "user-1"),
            username: "admin",
            exp: .init(value: Date().addingTimeInterval(3_600)),
        )
        let token = try await keys.sign(payload)
        do {
            let req = request(app, path: "/api/vms?ticket=\(ticket)")
            req.headers.add(name: .authorization, value: "Bearer \(token)")
            let response = try await jwt.respond(to: req, chainingTo: OKResponder())
            #expect(response.status == .ok)
            #expect(req.authenticatedUser?.authMethod == "jwt")
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-1")
            #expect(leftover != nil)
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `owner device state SSE spends ticket for that Workload`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: "vm-state")
        do {
            let req = request(app, path: "/api/vms/vm-state/state?ticket=\(ticket)")
            let response = try await jwt.respond(to: req, chainingTo: OKResponder())
            #expect(response.status == .ok)
            #expect(req.authenticatedUser?.authMethod == "ticket")
            #expect(req.authenticatedUser?.userId == "user-1")
            let spent = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-state")
            #expect(spent == nil)
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `metrics stream ticket is Workload scoped`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: "vm-a")
        do {
            let req = request(app, path: "/api/vms/vm-b/metrics/stream?ticket=\(ticket)")
            do {
                _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                Issue.record("expected unauthorized for the other Workload")
            } catch let error as AbortError {
                #expect(error.status == .unauthorized)
            }
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-a")
            #expect(leftover == nil, "wrong-Workload spend still consumes the ticket")
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `logs SSE rejects a Workload scoped ticket`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: "vm-1")
        do {
            let req = request(app, path: "/api/logs/stream?ticket=\(ticket)")
            do {
                _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                Issue.record("expected unauthorized for a VM-scoped ticket on logs SSE")
            } catch let error as AbortError {
                #expect(error.status == .unauthorized)
            }
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-1")
            #expect(leftover == nil, "unscoped spend still consumes a VM-scoped ticket")
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `logs SSE spends unscoped ticket`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: nil)
        do {
            let req = request(app, path: "/api/logs/stream?ticket=\(ticket)")
            let response = try await jwt.respond(to: req, chainingTo: OKResponder())
            #expect(response.status == .ok)
            #expect(req.authenticatedUser?.username == "admin")
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `diagnostics bundle download does not spend a Device ticket`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: nil)
        do {
            let req = request(
                app,
                path: "/api/diagnostics/bundle/task-1/download?ticket=\(ticket)",
            )
            do {
                _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                Issue.record("expected unauthorized without Bearer")
            } catch let error as AbortError {
                #expect(error.status == .unauthorized)
            }
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket)
            #expect(leftover?.userID == "user-1", "diagnostics download must not spend ?ticket=")
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `stray ticket on diagnostics download still allows Bearer JWT`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket(vmID: nil)
        let payload = UserPayload(
            sub: .init(value: "user-1"),
            username: "admin",
            exp: .init(value: Date().addingTimeInterval(3_600)),
        )
        let token = try await keys.sign(payload)
        do {
            let req = request(
                app,
                path: "/api/diagnostics/bundle/task-1/download?ticket=\(ticket)",
            )
            req.headers.add(name: .authorization, value: "Bearer \(token)")
            let response = try await jwt.respond(to: req, chainingTo: OKResponder())
            #expect(response.status == .ok)
            #expect(req.authenticatedUser?.authMethod == "jwt")
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket)
            #expect(leftover != nil)
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `home tunnel does not spend Device ticket`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let ticket = await mintTicket()
        do {
            let req = request(
                app,
                path: "/api/home/devices/peer-1/v1/vms/vm-1/vnc?ticket=\(ticket)",
            )
            do {
                _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                Issue.record("expected unauthorized without session or Bearer")
            } catch let error as AbortError {
                #expect(error.status == .unauthorized)
            }
            let leftover = await WebSocketTicketStore.shared.validateTicket(ticket, forVMID: "vm-1")
            #expect(leftover != nil)
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }
}
