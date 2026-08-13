import Foundation

/// Pairwise pin of a peer Device certificate (PAS-76).
///
/// Fingerprints are SHA-256 of the leaf certificate DER, lowercase hex.
/// Pairing (PAS-45) writes pins; this ticket only stores and looks them up.
public struct PeerPin: Codable, Sendable, Equatable {
    public var hostId: String
    public var fingerprint: String
    public var pinnedAt: String

    public init(hostId: String, fingerprint: String, pinnedAt: String) {
        self.hostId = hostId
        self.fingerprint = fingerprint.lowercased()
        self.pinnedAt = pinnedAt
    }
}

/// File-backed pairwise pin store at `dataDir/agent/pins.json`.
///
/// Independent of SQLite so local VM runtime (PAS-47/90) does not depend
/// on mesh trust material.
public final class PeerPinStore: @unchecked Sendable {
    public static let fileName = "pins.json"

    public let fileURL: URL
    private let lock = NSLock()

    public init(dataDir: URL) {
        self.fileURL = dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(Self.fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [PeerPin] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func contains(fingerprint: String) -> Bool {
        let needle = fingerprint.lowercased()
        return load().contains { $0.fingerprint == needle }
    }

    public func pin(forHostId hostId: String) -> PeerPin? {
        load().first { $0.hostId == hostId }
    }

    @discardableResult
    public func pin(hostId: String, fingerprint: String, now: Date = Date()) throws -> PeerPin {
        let entry = PeerPin(
            hostId: hostId,
            fingerprint: fingerprint,
            pinnedAt: iso8601.string(from: now),
        )
        lock.lock()
        defer { lock.unlock() }
        var pins = loadLocked()
        pins.removeAll {
            $0.hostId == hostId || $0.fingerprint == entry.fingerprint
        }
        pins.append(entry)
        try persistLocked(pins)
        return entry
    }

    public func unpin(hostId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var pins = loadLocked()
        pins.removeAll { $0.hostId == hostId }
        try persistLocked(pins)
    }

    private func loadLocked() -> [PeerPin] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return []
        }
        return (try? JSONDecoder().decode([PeerPin].self, from: data)) ?? []
    }

    private func persistLocked(_ pins: [PeerPin]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pins)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path,
        )
    }
}
