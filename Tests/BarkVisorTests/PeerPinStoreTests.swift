import Foundation
import Testing
@testable import BarkVisorCore

@Suite("PeerPinStore")
struct PeerPinStoreTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pins-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `pin persists and matches case insensitive fingerprint`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeerPinStore(dataDir: dir)
        let hostId = UUID().uuidString
        try store.pin(hostId: hostId, fingerprint: "ABCdef")
        #expect(store.contains(fingerprint: "abcdef"))
        #expect(store.contains(fingerprint: "ABCDEF"))
        #expect(store.pin(forHostId: hostId)?.fingerprint == "abcdef")

        let reloaded = PeerPinStore(dataDir: dir)
        #expect(reloaded.contains(fingerprint: "abcdef"))

        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }

    @Test func `unpin removes only that host`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeerPinStore(dataDir: dir)
        try store.pin(hostId: "a", fingerprint: "aa")
        try store.pin(hostId: "b", fingerprint: "bb")
        try store.unpin(hostId: "a")
        #expect(!store.contains(fingerprint: "aa"))
        #expect(store.contains(fingerprint: "bb"))
    }

    @Test func `empty store does not require network or sqlite`() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pins-empty-\(UUID().uuidString)",
        )
        let store = PeerPinStore(dataDir: dir)
        #expect(store.load().isEmpty)
        #expect(!store.contains(fingerprint: "deadbeef"))
    }
}
