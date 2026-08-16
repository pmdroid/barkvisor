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
        #expect(try store.contains(fingerprint: "abcdef"))
        #expect(try store.contains(fingerprint: "ABCDEF"))
        #expect(try store.pin(forHostId: hostId)?.fingerprint == "abcdef")

        let reloaded = PeerPinStore(dataDir: dir)
        #expect(try reloaded.contains(fingerprint: "abcdef"))

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
        #expect(try store.contains(fingerprint: "aa") == false)
        #expect(try store.contains(fingerprint: "bb"))
    }

    @Test func `empty store does not require network or sqlite`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pins-empty-\(UUID().uuidString)",
        )
        let store = PeerPinStore(dataDir: dir)
        #expect(try store.load().isEmpty)
        #expect(try store.contains(fingerprint: "deadbeef") == false)
    }

    @Test func `load uses memory cache until a write`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeerPinStore(dataDir: dir)
        try store.pin(hostId: "a", fingerprint: "aa")
        try Data("[]".utf8).write(to: store.fileURL, options: [.atomic])
        #expect(try store.load().map(\.hostId) == ["a"])
        try store.unpin(hostId: "a")
        #expect(try store.load().isEmpty)
    }

    @Test func `corrupt pins json does not drop existing pins`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PeerPinStore(dataDir: dir)
        try store.pin(hostId: "a", fingerprint: "aa")
        try store.pin(hostId: "b", fingerprint: "bb")
        let before = try Data(contentsOf: store.fileURL)
        try Data("{".utf8).write(to: store.fileURL, options: [.atomic])
        let truncated = try Data(contentsOf: store.fileURL)

        // In-process cache keeps the last good pins for handshake.
        #expect(try store.load().map(\.hostId).sorted() == ["a", "b"])
        #expect(try store.contains(fingerprint: "aa"))
        // Writes still read disk and refuse to clobber the corrupt file.
        #expect(throws: PeerPinStoreError.self) {
            try store.pin(hostId: "c", fingerprint: "cc")
        }
        let other = PeerPinStore(dataDir: dir)
        #expect(throws: PeerPinStoreError.self) {
            try other.load()
        }
        #expect(try Data(contentsOf: store.fileURL) == truncated)
        #expect(before != truncated)
    }
}
