import Foundation

/// File-backed Home device registry (PAS-34).
///
/// Independent of SQLite so local VM runtime (PAS-47 / PAS-90) does not
/// depend on mesh membership. Pairing redeem/join writes rows; the
/// dashboard (PAS-52) reads them and best-effort probes members.
public final class DeviceRegistry: @unchecked Sendable {
    public static let fileName = "devices.json"

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

    public func load() throws -> [DeviceRecord] {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func record(forHostId hostId: String) throws -> DeviceRecord? {
        try load().first { $0.hostId == hostId }
    }

    @discardableResult
    public func upsert(
        hostId: String,
        fingerprint: String,
        displayName: String? = nil,
        agentHost: String? = nil,
        agentPort: Int = Config.agentPort,
        now: Date = Date(),
    ) throws -> DeviceRecord {
        let port = (1 ... 65_535).contains(agentPort) ? agentPort : Config.agentPort
        let host = agentHost.flatMap(PairingPayload.sanitizeProxyHost)
        lock.lock()
        defer { lock.unlock() }
        var rows = try loadLocked()
        let existing = rows.first { $0.hostId == hostId || $0.fingerprint == fingerprint.lowercased() }
        let entry = DeviceRecord(
            hostId: hostId,
            fingerprint: fingerprint,
            displayName: normalizedDisplayName(displayName) ?? existing?.displayName,
            agentHost: host,
            agentPort: port,
            pairedAt: iso8601.string(from: now),
        )
        rows.removeAll { $0.hostId == hostId || $0.fingerprint == entry.fingerprint }
        rows.append(entry)
        try persistLocked(rows)
        return entry
    }

    /// Record a member's last known name without changing its connection or
    /// pairing material. The health probe calls this after a successful read.
    public func updateDisplayName(hostId: String, displayName: String?) throws {
        guard let displayName = normalizedDisplayName(displayName) else { return }
        lock.lock()
        defer { lock.unlock() }
        var rows = try loadLocked()
        guard let index = rows.firstIndex(where: { $0.hostId == hostId }) else { return }
        guard rows[index].displayName != displayName else { return }
        rows[index].displayName = displayName
        try persistLocked(rows)
    }

    public func remove(hostId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var rows = try loadLocked()
        rows.removeAll { $0.hostId == hostId }
        try persistLocked(rows)
    }

    private func loadLocked() throws -> [DeviceRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw DeviceRegistryError.corruptMaterial(
                "unable to read devices.json: \(error.localizedDescription)",
            )
        }
        do {
            return try JSONDecoder().decode([DeviceRecord].self, from: data)
        } catch {
            throw DeviceRegistryError.corruptMaterial(
                "unable to decode devices.json: \(error.localizedDescription)",
            )
        }
    }

    private func persistLocked(_ rows: [DeviceRecord]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(rows)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path,
        )
    }

    private func normalizedDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return nil
        }
        return trimmed
    }
}

public enum DeviceRegistryError: Error, LocalizedError, Sendable, Equatable {
    case corruptMaterial(String)

    public var errorDescription: String? {
        switch self {
        case let .corruptMaterial(reason): "Device registry is corrupt: \(reason)"
        }
    }
}

/// Local catalog: this Device plus paired members. Never probes the network.
public enum HomeDeviceDirectory {
    public static func list(
        dataDir: URL,
        hostId: String,
        displayName: String? = nil,
        agentPort: Int = Config.agentPort,
        devices: DeviceRegistry? = nil,
    ) -> HomeDeviceList {
        let fingerprint = existingDeviceFingerprint(dataDir: dataDir)
        let selfDevice = HomeDevice(
            hostId: hostId,
            role: "self",
            fingerprint: fingerprint,
            displayName: displayName,
            agentHost: nil,
            agentPort: agentPort,
            pairedAt: nil,
        )
        let store = devices ?? DeviceRegistry(dataDir: dataDir)
        let members: [HomeDevice]
        do {
            members = try store.load()
                .filter { $0.hostId != hostId }
                .sorted { $0.hostId < $1.hostId }
                .map { row in
                    HomeDevice(
                        hostId: row.hostId,
                        role: "member",
                        fingerprint: row.fingerprint,
                        displayName: row.displayName,
                        agentHost: row.agentHost,
                        agentPort: row.agentPort,
                        pairedAt: row.pairedAt,
                    )
                }
        } catch {
            // Corrupt mesh state must not hide this Device (PAS-47 / PAS-90).
            return HomeDeviceList(devices: [selfDevice])
        }
        return HomeDeviceList(devices: [selfDevice] + members)
    }

    public static func existingDeviceFingerprint(dataDir: URL) -> String? {
        let url = HomeCAService.agentDirectory(in: dataDir)
            .appendingPathComponent(HomeCAService.deviceCertificateFileName)
        guard let pem = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return try? DeviceTrust.fingerprint(pem: pem)
    }
}
