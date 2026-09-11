import Foundation
import GRDB
import JWTKit
import NIOCore
import Testing
import Vapor
@testable import BarkVisor
@testable import BarkVisorCore

private struct OKResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}

@Suite("Auth bypass front door", .serialized)
struct AuthBypassTests {
    @Test func `bypass matrix by mode and peer`() {
        #expect(!AuthBypass.allows(mode: .secure, peerIP: "127.0.0.1"))
        #expect(!AuthBypass.allows(mode: .secure, peerIP: "10.0.0.2"))
        #expect(AuthBypass.allows(mode: .loopback, peerIP: "127.0.0.1"))
        #expect(AuthBypass.allows(mode: .loopback, peerIP: "::1"))
        #expect(AuthBypass.allows(mode: .loopback, peerIP: "::ffff:127.0.0.1"))
        #expect(!AuthBypass.allows(mode: .loopback, peerIP: "10.0.0.2"))
        #expect(!AuthBypass.allows(mode: .loopback, peerIP: nil))
        #expect(AuthBypass.allows(mode: .disabled, peerIP: "10.0.0.2"))
        #expect(AuthBypass.allows(mode: .disabled, peerIP: nil))
    }

    @Test func `pairing join is loopback-only when disabled`() {
        #expect(AuthBypass.pairingJoinAllowed(mode: .secure, peerIP: "10.0.0.2"))
        #expect(AuthBypass.pairingJoinAllowed(mode: .loopback, peerIP: "10.0.0.2"))
        #expect(AuthBypass.pairingJoinAllowed(mode: .disabled, peerIP: "127.0.0.1"))
        #expect(!AuthBypass.pairingJoinAllowed(mode: .disabled, peerIP: "10.0.0.2"))
        #expect(!AuthBypass.pairingJoinAllowed(mode: .disabled, peerIP: nil))
    }

    @Test func `proxied requests never qualify as loopback`() {
        #expect(!AuthBypass.allows(mode: .loopback, peerIP: "127.0.0.1", proxied: true))
        #expect(AuthBypass.allows(mode: .loopback, peerIP: "127.0.0.1", proxied: false))
        #expect(AuthBypass.allows(mode: .disabled, peerIP: "10.0.0.2", proxied: true))
        #expect(!AuthBypass.pairingJoinAllowed(mode: .disabled, peerIP: "127.0.0.1", proxied: true))
        #expect(AuthBypass.pairingJoinAllowed(mode: .disabled, peerIP: "127.0.0.1", proxied: false))
    }

    @Test func `host and origin guard rejects drive-by`() {
        let extras: Set = ["studio.local", "192.168.1.10"]
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "localhost:7777",
                origin: nil,
                method: "GET",
                extras: extras,
            ) == .allow,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "evil.example",
                origin: nil,
                method: "GET",
                extras: extras,
            ) == .rejectHost,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: nil,
                origin: nil,
                method: "GET",
                extras: extras,
            ) == .rejectHost,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "127.0.0.1:7777",
                origin: "http://evil.example",
                method: "POST",
                extras: extras,
            ) == .rejectOrigin,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "localhost",
                origin: "http://localhost:7777",
                method: "POST",
                extras: extras,
            ) == .allow,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "192.168.1.10:7777",
                origin: "http://192.168.1.10:7777",
                method: "PUT",
                extras: extras,
            ) == .allow,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "localhost",
                origin: "null",
                method: "DELETE",
                extras: extras,
            ) == .rejectOrigin,
        )
        #expect(
            AuthFrontDoorGuard.evaluate(
                host: "localhost",
                origin: "http://evil.example",
                method: "GET",
                extras: extras,
            ) == .allow,
        )
        #expect(AuthFrontDoorGuard.normalizedHost("[::1]:7777") == "::1")
        #expect(AuthFrontDoorGuard.hostIsAllowed("studio.local:7777", extras: extras))
    }

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
        await keys.add(hmac: .init(from: "auth-bypass-test-secret"), digestAlgorithm: .sha256)
        return keys
    }

    private func request(
        _ app: Application,
        method: HTTPMethod = .GET,
        path: String,
        peerIP: String? = nil,
    ) -> Request {
        Request(
            application: app,
            method: method,
            url: URI(string: path),
            remoteAddress: peerIP.flatMap { try? SocketAddress(ipAddress: $0, port: 4_321) },
            on: app.eventLoopGroup.next(),
        )
    }

    @Test func `jwt middleware disabled bypasses without bearer when host is local`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                let response = try await jwt.respond(to: req, chainingTo: OKResponder())
                #expect(response.status == .ok)
                #expect(req.authenticatedUser?.userId == AuthBypass.syntheticUserId)
                #expect(req.authenticatedUser?.authMethod == AuthBypass.syntheticAuthMethod)
                #expect(req.authenticatedUser?.role == UserRole.admin.rawValue)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `jwt middleware disabled rejects bad host`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "evil.example")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected forbidden host")
                } catch let error as AbortError {
                    #expect(error.status == .forbidden)
                }
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `jwt middleware disabled rejects mutating origin`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, method: .POST, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                req.headers.replaceOrAdd(name: .origin, value: "http://evil.example")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected forbidden origin")
                } catch let error as AbortError {
                    #expect(error.status == .forbidden)
                }
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `jwt middleware loopback without peer still requires bearer`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected unauthorized without loopback peer")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `home tunnel middleware disabled bypasses`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let hop = HomeTunnelAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms/vm-1/console")
                req.headers.replaceOrAdd(name: .host, value: "127.0.0.1:7777")
                let response = try await hop.respond(to: req, chainingTo: OKResponder())
                #expect(response.status == .ok)
                #expect(req.authenticatedUser?.authMethod == "bypass")
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `setup middleware lets api through when disabled`() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let setup = SetupMiddleware(dbPool: pool)
        #expect(!setup.isSetupComplete)
        let app = try await makeApp()
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms")
                let response = try await setup.respond(to: req, chainingTo: OKResponder())
                #expect(response.status == .ok)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `login short-circuit mints bypass jwt`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let limiter = RateLimitMiddleware(
            store: RateLimitStore(maxAttempts: 100, window: 60),
        )
        let controller = AuthController(keys: keys, loginRateLimit: limiter)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, method: .POST, path: "/api/auth/login")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                let response = try await controller.login(req: req)
                #expect(response.status == .ok)
                let body = response.body.string ?? ""
                #expect(body.contains("\"role\":\"admin\""))
                #expect(req.authenticatedUser?.userId == "local-bypass")
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `loopback bypass refuses proxied requests`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                req.headers.replaceOrAdd(name: "X-Forwarded-For", value: "203.0.113.9")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected unauthorized for proxied loopback peer")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `loopback bypass admits direct loopback peer`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                req.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                let response = try await jwt.respond(to: req, chainingTo: OKResponder())
                #expect(response.status == .ok)
                #expect(req.authenticatedUser?.userId == AuthBypass.syntheticUserId)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `bypass jwt is only honored where bypass is allowed`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        let token = try await AuthService.signBypassAccessToken(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let remote = request(app, path: "/api/vms", peerIP: "10.0.0.2")
                remote.headers.replaceOrAdd(name: .host, value: "studio.local:7777")
                remote.headers.bearerAuthorization = .init(token: token)
                do {
                    _ = try await jwt.respond(to: remote, chainingTo: OKResponder())
                    Issue.record("expected unauthorized for bypass token from remote peer")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }

                let local = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                local.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                local.headers.bearerAuthorization = .init(token: token)
                let response = try await jwt.respond(to: local, chainingTo: OKResponder())
                #expect(response.status == .ok)
                #expect(local.authenticatedUser?.userId == AuthBypass.syntheticUserId)
            }
            try await AuthModeTesting.withOverride(.secure) {
                let stale = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                stale.headers.replaceOrAdd(name: .host, value: "localhost:7777")
                stale.headers.bearerAuthorization = .init(token: token)
                do {
                    _ = try await jwt.respond(to: stale, chainingTo: OKResponder())
                    Issue.record("expected unauthorized for bypass token in secure mode")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }
}
