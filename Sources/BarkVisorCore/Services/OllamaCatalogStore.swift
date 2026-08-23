import Foundation

/// Persisted Home Ollama map. Re-probed after restart (PAS-269).
public final class OllamaCatalogStore: @unchecked Sendable {
    public static let fileName = "ollama-catalog.json"

    public let fileURL: URL
    private let lock = NSLock()
    private var cached: OllamaPersistedMap?

    public init(dataDir: URL) {
        self.fileURL = dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(Self.fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> OllamaPersistedMap {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func save(_ map: OllamaPersistedMap) throws {
        lock.lock()
        defer { lock.unlock() }
        try persistLocked(map)
    }

    public func upsert(_ snapshot: OllamaDeviceSnapshot) throws -> OllamaPersistedMap {
        lock.lock()
        defer { lock.unlock() }
        var map = try loadLocked()
        map.devices.removeAll { $0.hostId == snapshot.hostId }
        map.devices.append(snapshot)
        map.refreshedAt = snapshot.probedAt
        try persistLocked(map)
        return map
    }

    private func loadLocked() throws -> OllamaPersistedMap {
        if let cached { return cached }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let empty = OllamaPersistedMap()
            cached = empty
            return empty
        }
        let data = try Data(contentsOf: fileURL)
        let map = try JSONDecoder().decode(OllamaPersistedMap.self, from: data)
        cached = map
        return map
    }

    private func persistLocked(_ map: OllamaPersistedMap) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(map)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path,
        )
        cached = map
    }
}
