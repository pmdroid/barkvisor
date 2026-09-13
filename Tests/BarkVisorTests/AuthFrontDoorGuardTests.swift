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

@Suite("Front door guard", .serialized)
struct AuthFrontDoorGuardTests {
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

    private func makeDatabaseApp() async throws -> (Application, AppDatabase) {
        let app = try await makeApp()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let database = try AppDatabase(path: dir.appendingPathComponent("test.sqlite").path)
        try database.migrate()
        app.database = database
        return (app, database)
    }

    @Test func `bearer on rejected host demotes to unauthorized instead of forbidden`() async throws {
        let app = try await makeApp()
        let keys = await makeKeys()
        let jwt = JWTAuthMiddleware(keys: keys)
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "evil.example")
                req.headers.bearerAuthorization = .init(token: "not-a-real.jwt")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected unauthorized after demotion")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
                #expect(req.authenticatedUser == nil)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `cookie only request on rejected host demotes to unauthorized`() async throws {
        let app = try await makeApp()
        let jwt = await JWTAuthMiddleware(keys: makeKeys())
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms")
                req.headers.replaceOrAdd(name: .host, value: "evil.example")
                req.headers.replaceOrAdd(name: "Cookie", value: "barkvisor_session=abc123")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected unauthorized for cookie credential")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
                #expect(req.authenticatedUser == nil)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `ticket query on rejected host demotes instead of forbidden`() async throws {
        let app = try await makeApp()
        let jwt = await JWTAuthMiddleware(keys: makeKeys())
        do {
            try await AuthModeTesting.withOverride(.disabled) {
                let req = request(app, path: "/api/vms?ticket=dummy123")
                req.headers.replaceOrAdd(name: .host, value: "evil.example")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected unauthorized for ticketed demotion")
                } catch let error as AbortError {
                    #expect(error.status == .unauthorized)
                }
                #expect(req.authenticatedUser == nil)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `advertised host from device url settings is allowed`() async throws {
        let (app, database) = try await makeDatabaseApp()
        let jwt = await JWTAuthMiddleware(keys: makeKeys())
        try await database.pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: "https://studio.example:8443",
                updateDeviceUrl: true,
                db: db,
            )
        }
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                req.headers.replaceOrAdd(name: .host, value: "studio.example:8443")
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

    @Test func `host mismatch beyond advertised stays forbidden without credentials`() async throws {
        let (app, database) = try await makeDatabaseApp()
        let jwt = await JWTAuthMiddleware(keys: makeKeys())
        try await database.pool.write { db in
            try RemoteAccessSettings.save(
                deviceUrl: "https://studio.example:8443",
                updateDeviceUrl: true,
                db: db,
            )
        }
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                req.headers.replaceOrAdd(name: .host, value: "evil.example")
                do {
                    _ = try await jwt.respond(to: req, chainingTo: OKResponder())
                    Issue.record("expected forbidden for unlisted host")
                } catch let error as AbortError {
                    #expect(error.status == .forbidden)
                }
                #expect(req.authenticatedUser == nil)
            }
            await stop(app)
        } catch {
            await stop(app)
            throw error
        }
    }

    @Test func `legacy stored device url with scheme and path is parsed and allowed`() async throws {
        let (app, database) = try await makeDatabaseApp()
        let jwt = await JWTAuthMiddleware(keys: makeKeys())
        try await database.pool.write { db in
            try AppSetting(key: "remote_access.advertise_url", value: "https://legacy.example:8443/up")
                .save(db, onConflict: .replace)
        }
        do {
            try await AuthModeTesting.withOverride(.loopback) {
                let req = request(app, path: "/api/vms", peerIP: "127.0.0.1")
                req.headers.replaceOrAdd(name: .host, value: "legacy.example:8443")
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

    @Test func `comma separated stored advertise list yields every host`() {
        let hosts = AuthFrontDoorGuard.advertisedHosts(
            from: "https://alpha.example:8443/up, beta.example ,bad,,https://gamma.example",
        )
        #expect(hosts.contains("alpha.example"))
        #expect(hosts.contains("beta.example"))
        #expect(hosts.contains("gamma.example"))
        #expect(!hosts.contains { $0.isEmpty })
    }
}
