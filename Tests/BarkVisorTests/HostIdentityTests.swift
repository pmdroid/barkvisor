import Foundation
import Testing
@testable import BarkVisorCore

@Suite("HostIdentity")
struct HostIdentityTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "host-id-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `creates uuid file and reuses it`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = HostIdentity.loadOrCreate(dataDir: dir)
        let second = HostIdentity.loadOrCreate(dataDir: dir)
        #expect(first == second)

        let file = HostIdentity.fileURL(in: dir)
        #expect(file.lastPathComponent == "host-id")
        let raw = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(raw == first.uuidString)
    }

    @Test func `file is owner read write only`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = HostIdentity.loadOrCreate(dataDir: dir)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: HostIdentity.fileURL(in: dir).path,
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }

    @Test func `replaces invalid file contents`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = HostIdentity.fileURL(in: dir)
        try Data("not-a-uuid".utf8).write(to: file)

        let id = HostIdentity.loadOrCreate(dataDir: dir)
        #expect(UUID(uuidString: id.uuidString) != nil)
        let stored = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stored == id.uuidString)
        #expect(stored != "not-a-uuid")
    }

    @Test func `accepts uuid with surrounding whitespace`() throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = UUID()
        try Data("\(existing.uuidString.lowercased())\n".utf8)
            .write(to: HostIdentity.fileURL(in: dir))

        let loaded = HostIdentity.loadOrCreate(dataDir: dir)
        #expect(loaded == existing)
    }

    @Test func `distinct data dirs get distinct ids`() throws {
        let a = try isolatedDir()
        let b = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }

        let idA = HostIdentity.loadOrCreate(dataDir: a)
        let idB = HostIdentity.loadOrCreate(dataDir: b)
        #expect(idA != idB)
    }
}
