import Foundation
import Testing
@testable import BarkVisorCore

struct AuthModeTests {
    @Test func `env wins over persisted and default`() {
        #expect(
            AuthModeStore.resolve(
                envValue: "disabled",
                persistedMode: "loopback",
                acknowledged: false,
            ) == .disabled,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: "LOOPBACK",
                persistedMode: "disabled",
                acknowledged: true,
            ) == .loopback,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: " secure ",
                persistedMode: "disabled",
                acknowledged: true,
            ) == .secure,
        )
    }

    @Test func `invalid env falls through to settings then secure`() {
        #expect(
            AuthModeStore.resolve(
                envValue: "wide-open",
                persistedMode: "loopback",
                acknowledged: false,
            ) == .loopback,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: "",
                persistedMode: nil,
                acknowledged: false,
            ) == .secure,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: "nope",
                acknowledged: true,
            ) == .secure,
        )
    }

    @Test func `persisted disabled requires acknowledgement`() {
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: "disabled",
                acknowledged: false,
            ) == .secure,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: "disabled",
                acknowledged: true,
            ) == .disabled,
        )
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: "loopback",
                acknowledged: false,
            ) == .loopback,
        )
    }

    @Test func `env locked only for known modes`() {
        #expect(AuthModeStore.envLocked(envValue: "disabled"))
        #expect(AuthModeStore.envLocked(envValue: "loopback"))
        #expect(AuthModeStore.envLocked(envValue: "secure"))
        #expect(!AuthModeStore.envLocked(envValue: "nope"))
        #expect(!AuthModeStore.envLocked(envValue: nil))
        #expect(!AuthModeStore.envLocked(envValue: ""))
    }

    @Test func `persist round trip honors ack for disabled`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let previousMode = UserDefaults.standard.object(forKey: AuthModeStore.modeKey)
        let previousAck = UserDefaults.standard.object(forKey: AuthModeStore.ackKey)
        defer {
            UserDefaults.standard.set(previousMode, forKey: AuthModeStore.modeKey)
            UserDefaults.standard.set(previousAck, forKey: AuthModeStore.ackKey)
        }

        AuthModeStore.persist(mode: .disabled, acknowledged: false, dataDir: dir)
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: AuthModeStore.persistedMode(dataDir: dir),
                acknowledged: AuthModeStore.acknowledged(dataDir: dir),
            ) == .secure,
        )

        AuthModeStore.persist(mode: .disabled, acknowledged: true, dataDir: dir)
        #expect(
            AuthModeStore.resolve(
                envValue: nil,
                persistedMode: AuthModeStore.persistedMode(dataDir: dir),
                acknowledged: AuthModeStore.acknowledged(dataDir: dir),
            ) == .disabled,
        )

        AuthModeStore.persist(mode: .loopback, acknowledged: true, dataDir: dir)
        #expect(AuthModeStore.parse(AuthModeStore.persistedMode(dataDir: dir)) == .loopback)
        #expect(!AuthModeStore.acknowledged(dataDir: dir))
    }
}
