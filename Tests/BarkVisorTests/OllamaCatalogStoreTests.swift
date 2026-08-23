import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama catalog persist (PAS-269)")
struct OllamaCatalogStoreTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ollama-map-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `upsert persists 0600 and replaces same Device`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OllamaCatalogStore(dataDir: dir)
        let snap = OllamaDeviceSnapshot(
            hostId: "desk",
            installed: true,
            reachable: true,
            installHint: "brew",
            probedAt: "2026-08-22T00:00:00Z",
            models: [OllamaLocalModel(name: "llama3:latest", running: false)],
        )
        _ = try store.upsert(snap)
        #expect(try store.load().devices.count == 1)
        var again = snap
        again.reachable = false
        again.models = []
        _ = try store.upsert(again)
        #expect(try store.load().devices.count == 1)
        #expect(try store.load().devices[0].reachable == false)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }
}
