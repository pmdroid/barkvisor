import Foundation
import Testing
@testable import BarkVisorCore

struct ComposeRuntimeTests {
    @Test func `writeProject quotes env values and keeps keys as lines`() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-compose-env-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let dir = try ComposeRuntime.writeProject(
            id: "app-1",
            yaml: "services: {}\n",
            env: ["FOO": "bar", "BAZ": "has space"],
            dataDir: dataDir,
        )
        let body = try String(
            contentsOf: dir.appendingPathComponent(".env"),
            encoding: .utf8,
        )
        #expect(body == "BAZ='has space'\nFOO='bar'\n")
    }

    @Test func `writeProject rejects env keys that inject extra lines`() {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-compose-env-bad-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeRuntime.writeProject(
                id: "app-1",
                yaml: "services: {}\n",
                env: ["FOO\nEVIL": "1"],
                dataDir: dataDir,
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "invalid compose env key")
        let envURL = ComposeRuntime.projectDirectory(id: "app-1", dataDir: dataDir)
            .appendingPathComponent(".env")
        #expect(!FileManager.default.fileExists(atPath: envURL.path))
    }

    @Test func `writeProject rejects compose control env keys`() {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-compose-env-ctl-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let error = #expect(throws: BarkVisorError.self) {
            _ = try ComposeRuntime.writeProject(
                id: "app-1",
                yaml: "services: {}\n",
                env: ["COMPOSE_ENV_FILES": "/etc/passwd"],
                dataDir: dataDir,
            )
        }
        guard case let .badRequest(message) = error else {
            Issue.record("expected badRequest")
            return
        }
        #expect(message == "invalid compose env key")
    }

    @Test func `writeProject single-quotes dollar env values`() throws {
        let dataDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-compose-env-dollar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dataDir) }
        let dir = try ComposeRuntime.writeProject(
            id: "app-1",
            yaml: "services: {}\n",
            env: ["K": "$HOME"],
            dataDir: dataDir,
        )
        let body = try String(
            contentsOf: dir.appendingPathComponent(".env"),
            encoding: .utf8,
        )
        #expect(body == "K='$HOME'\n")
    }
}
