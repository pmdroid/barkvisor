import Foundation

/// Durable host identity: a UUID persisted at `dataDir/host-id`.
///
/// Mirrors `Config.jwtSecret` (atomic write + 0600). One BarkVisor process
/// owns one data dir and therefore one host id (PAS-42).
public enum HostIdentity {
    public static let fileName = "host-id"

    public static func fileURL(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    /// Load the persisted UUID, or create and store a new one.
    ///
    /// Invalid / unreadable files are replaced. Persistence failures are
    /// logged; the in-memory UUID is still returned so the process can start.
    public static func loadOrCreate(dataDir: URL) -> UUID {
        let file = fileURL(in: dataDir)
        if let existing = read(from: file) {
            return existing
        }
        let id = UUID()
        persist(id, at: file, ensuringDirectory: dataDir)
        return id
    }

    private static func read(from file: URL) -> UUID? {
        guard let data = try? Data(contentsOf: file),
              let raw = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let uuid = UUID(uuidString: raw) {
            return uuid
        }
        Log.server.warning("Ignoring invalid host-id at \(file.path)")
        return nil
    }

    private static func persist(_ id: UUID, at file: URL, ensuringDirectory dataDir: URL) {
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        } catch {
            Log.server.critical(
                """
                Failed to create data directory for host-id: \(error.localizedDescription). \
                Host identity will not persist across restarts.
                """,
            )
        }
        do {
            try Data(id.uuidString.utf8).write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path,
            )
            Log.server.info("Generated and stored host-id on disk")
        } catch {
            Log.server.critical(
                """
                Failed to write host-id to disk: \(error.localizedDescription). \
                A new host identity will be generated on every restart.
                """,
            )
        }
    }
}
