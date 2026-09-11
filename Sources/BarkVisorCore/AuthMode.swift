import Foundation

public enum AuthMode: String, Sendable, Codable, CaseIterable {
    case secure
    case loopback
    case disabled
}

public enum AuthModeStore: Sendable {
    public static let envKey = "BARKVISOR_AUTH_MODE"
    public static let modeKey = "authMode"
    public static let ackKey = "authDisabledAcknowledged"

    public static func parse(_ raw: String?) -> AuthMode? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return AuthMode(rawValue: trimmed)
    }

    public static func resolve(
        envValue: String?,
        persistedMode: String?,
        acknowledged: Bool,
    ) -> AuthMode {
        if let fromEnv = parse(envValue) {
            return fromEnv
        }
        guard let persisted = parse(persistedMode) else {
            return .secure
        }
        if persisted == .disabled, !acknowledged {
            return .secure
        }
        return persisted
    }

    public static func envLocked(envValue: String?) -> Bool {
        parse(envValue) != nil
    }

    public static func persist(mode: AuthMode, acknowledged: Bool, dataDir: URL) {
        PlatformPaths.setSettingsValue(mode.rawValue, forKey: modeKey, dataDir: dataDir)
        PlatformPaths.setSettingsValue(
            mode == .disabled && acknowledged,
            forKey: ackKey,
            dataDir: dataDir,
        )
    }

    public static func persistedMode(dataDir: URL) -> String? {
        PlatformPaths.settingsString(forKey: modeKey, dataDir: dataDir)
    }

    public static func acknowledged(dataDir: URL) -> Bool {
        PlatformPaths.settingsBool(forKey: ackKey, dataDir: dataDir, default: false)
    }
}

public enum AuthModeTesting: Sendable {
    @TaskLocal public static var current: AuthMode?

    public static func withOverride<T>(_ mode: AuthMode?, _ body: () throws -> T) rethrows -> T {
        try $current.withValue(mode, operation: body)
    }

    public static func withOverride<T>(
        _ mode: AuthMode?,
        _ body: () async throws -> T,
    ) async rethrows -> T {
        try await $current.withValue(mode, operation: body)
    }
}

extension Config {
    public static var authMode: AuthMode {
        if let override = AuthModeTesting.current {
            return override
        }
        return AuthModeStore.resolve(
            envValue: ProcessInfo.processInfo.environment[AuthModeStore.envKey],
            persistedMode: AuthModeStore.persistedMode(dataDir: dataDir),
            acknowledged: AuthModeStore.acknowledged(dataDir: dataDir),
        )
    }

    public static var authModeEnvLocked: Bool {
        AuthModeStore.envLocked(
            envValue: ProcessInfo.processInfo.environment[AuthModeStore.envKey],
        )
    }

    public static var persistedAuthMode: AuthMode {
        AuthModeStore.parse(AuthModeStore.persistedMode(dataDir: dataDir)) ?? .secure
    }

    public static func persistAuthMode(_ mode: AuthMode, acknowledged: Bool) {
        AuthModeStore.persist(mode: mode, acknowledged: acknowledged, dataDir: dataDir)
    }
}
