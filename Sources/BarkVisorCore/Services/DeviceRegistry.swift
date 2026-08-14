import Foundation

/// File-backed Home device registry (PAS-34).
///
/// Independent of SQLite so local VM runtime (PAS-47 / PAS-90) does not
/// depend on mesh membership. Pairing redeem/join writes rows; the
/// dashboard (PAS-52) only reads them.
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
        agentHost: String? = nil,
        agentPort: Int = Config.agentPort,
        now: Date = Date(),
    ) throws -> DeviceRecord {
        let port = (1 ... 65_535).contains(agentPort) ? agentPort : Config.agentPort
        let host = agentHost.flatMap(PairingPayload.sanitizeProxyHost)
        let entry = DeviceRecord(
            hostId: hostId,
            fingerprint: fingerprint,
            agentHost: host,
            agentPort: port,
            pairedAt: iso8601.string(from: now),
        )
        lock.lock()
        defer { lock.unlock() }
        var rows = try loadLocked()
        rows.removeAll { $0.hostId == hostId || $0.fingerprint == entry.fingerprint }
        rows.append(entry)
        try persistLocked(rows)
        return entry
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
                        displayName: nil,
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
