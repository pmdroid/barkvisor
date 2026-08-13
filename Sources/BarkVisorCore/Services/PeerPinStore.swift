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

    public func load() throws -> [PeerPin] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func contains(fingerprint: String) throws -> Bool {
        let needle = fingerprint.lowercased()
        return try load().contains { $0.fingerprint == needle }
    }

    public func pin(forHostId hostId: String) throws -> PeerPin? {
        try load().first { $0.hostId == hostId }
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
        var pins = try loadLocked()
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
        var pins = try loadLocked()
        pins.removeAll { $0.hostId == hostId }
        try persistLocked(pins)
    }

    private func loadLocked() throws -> [PeerPin] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PeerPinStoreError.corruptMaterial(
                "unable to read pins.json: \(error.localizedDescription)",
            )
        }
        do {
            return try JSONDecoder().decode([PeerPin].self, from: data)
        } catch {
            throw PeerPinStoreError.corruptMaterial(
                "unable to decode pins.json: \(error.localizedDescription)",
            )
        }
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

public enum PeerPinStoreError: Error, LocalizedError, Sendable, Equatable {
    case corruptMaterial(String)

    public var errorDescription: String? {
        switch self {
        case let .corruptMaterial(reason): "Peer pin store is corrupt: \(reason)"
        }
    }
}
