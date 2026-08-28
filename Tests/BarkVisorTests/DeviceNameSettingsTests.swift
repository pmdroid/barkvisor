import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

@Suite("Device display name")
final class DeviceNameSettingsTests {
    private let dbPool: DatabasePool
    private let tmpDir: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        tmpDir = tmp
        let pool = try DatabasePool(path: tmp.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        dbPool = pool
    }

    deinit {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func `unset name falls back to hostname`() throws {
        let name = try dbPool.read { try DeviceNameSettings.resolved(from: $0, hostname: "studio.local") }
        #expect(name == "studio.local")
    }

    @Test func `empty hostname fallback is Device`() {
        #expect(DeviceNameSettings.defaultName(hostname: "  ") == "Device")
    }

    @Test func `save trims and round-trips`() throws {
        try dbPool.write { db in
            let saved = try DeviceNameSettings.save("  Studio Mac  ", db: db)
            #expect(saved == "Studio Mac")
        }
        let name = try dbPool.read { try DeviceNameSettings.resolved(from: $0, hostname: "studio.local") }
        #expect(name == "Studio Mac")
    }

    @Test func `empty name is rejected`() {
        #expect(throws: BarkVisorError.self) {
            _ = try DeviceNameSettings.parse("   ")
        }
    }

    @Test func `overlong name is rejected`() {
        let raw = String(repeating: "a", count: DeviceNameSettings.maxLength + 1)
        #expect(throws: BarkVisorError.self) {
            _ = try DeviceNameSettings.parse(raw)
        }
    }

    @Test func `control characters are rejected`() {
        #expect(throws: BarkVisorError.self) {
            _ = try DeviceNameSettings.parse("Studio\nMac")
        }
    }

    @Test func `max length is accepted`() throws {
        let raw = String(repeating: "n", count: DeviceNameSettings.maxLength)
        #expect(try DeviceNameSettings.parse(raw) == raw)
    }
}
