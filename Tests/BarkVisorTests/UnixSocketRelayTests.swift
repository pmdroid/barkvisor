import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing
import Vapor
@testable import BarkVisorCore

@Suite(.serialized)
struct UnixSocketRelayTests {
    @Test func `relay preserves request and response bytes across unix peer checks`() async throws {
        try await exercise(allowed: true, correctDestination: true)
    }

    @Test func `relay rejects an untrusted unix client`() async throws {
        try await exercise(allowed: false, correctDestination: true)
    }

    @Test func `relay rejects an unexpected daemon uid`() async throws {
        try await exercise(allowed: true, correctDestination: false)
    }

    @Test func `waiting for a stopped relay fails`() async throws {
        let relay = UnixSocketRelay(
            listener: .tcp(host: "127.0.0.1", port: 0),
            destination: "/tmp/unused-relay.sock",
            destinationUID: WorkloadPrivilegeDrop.currentEUID(),
        )
        relay.stop()
        await #expect(throws: LocalManagementError.connectionLost) {
            try await relay.waitUntilListening()
        }
    }

    private func exercise(allowed: Bool, correctDestination: Bool) async throws {
        #if os(Windows)
            return
        #else
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("bv-relay-\(UUID().uuidString.prefix(8))")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let backendPath = directory.appendingPathComponent("backend.sock").path
            let gatewayPath = directory.appendingPathComponent("gateway.sock").path
            let uid = WorkloadPrivilegeDrop.currentEUID()
            var environment = Environment(name: "testing", arguments: ["relay-test"])
            environment.commandInput = CommandInput(arguments: ["relay-test"])
            let app = try await Application.make(environment)
            app.http.server.configuration.address = .unixDomainSocket(path: backendPath)
            app.on(.POST, "echo", body: .collect(maxSize: "1mb")) { request in
                Response(status: .ok, body: .init(buffer: request.body.data ?? ByteBuffer()))
            }
            try await app.startup()
            let gateway = UnixSocketRelay(
                listener: .unix(path: gatewayPath, mode: 0o600, allowedUIDs: allowed ? [uid] : []),
                destination: backendPath,
                destinationUID: uid,
            )
            let front = UnixSocketRelay(
                listener: .tcp(host: "127.0.0.1", port: 0),
                destination: gatewayPath,
                destinationUID: correctDestination ? uid : uid &+ 1,
            )
            let gatewayTask = Task {
                try await Task.sleep(for: .milliseconds(150))
                try await gateway.run()
            }
            let frontTask = Task { try await front.run() }
            do {
                try await gateway.waitUntilListening()
                try await front.waitUntilListening()
                let port = try #require(front.boundPort)
                let url = try #require(URL(string: "http://127.0.0.1:\(port)/echo"))
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.timeoutInterval = 3
                let body = Data((0 ..< 262_144).map { UInt8($0 % 251) })
                request.httpBody = body
                if allowed, correctDestination {
                    let (received, response) = try await URLSession.shared.data(for: request)
                    #expect((response as? HTTPURLResponse)?.statusCode == 200)
                    #expect(received == body)
                } else {
                    await #expect(throws: (any Error).self) {
                        _ = try await URLSession.shared.data(for: request)
                    }
                }
                front.stop()
                gateway.stop()
                try await frontTask.value
                try await gatewayTask.value
                try await app.asyncShutdown()
            } catch {
                front.stop()
                gateway.stop()
                _ = try? await frontTask.value
                _ = try? await gatewayTask.value
                try? await app.asyncShutdown()
                throw error
            }
        #endif
    }
}
