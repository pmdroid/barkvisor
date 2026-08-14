import Foundation
import JWTKit

/// Home JWT HMAC secret at `dataDir/jwt-secret` (atomic write + 0600).
///
/// Pairing (PAS-81) replaces the joiner file with the issuer secret so the
/// same username/password issues tokens both Devices accept. Local SQLite
/// still owns login; peers are not required at runtime (PAS-47 / PAS-90).
public enum JWTSecret {
    public static let fileName = "jwt-secret"

    public static func fileURL(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(fileName)
    }

    public static func load(dataDir: URL) -> String? {
        let file = fileURL(in: dataDir)
        guard let data = try? Data(contentsOf: file),
              let secret = String(data: data, encoding: .utf8)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
              !secret.isEmpty
        else {
            return nil
        }
        return secret
    }

    /// Replace the on-disk secret. Does not touch SQLite or QEMU.
    public static func replace(_ secret: String, dataDir: URL) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PairingError.invalidPayload("Issuer jwtSecret is missing")
        }
        do {
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let file = fileURL(in: dataDir)
            try Data(trimmed.utf8).write(to: file, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path,
            )
        } catch let error as PairingError {
            throw error
        } catch {
            throw PairingError.unavailable(
                "Unable to persist jwt-secret: \(error.localizedDescription)",
            )
        }
    }

    /// Overwrite the default HMAC signer so already-loaded keys pick up the
    /// paired secret without a process restart.
    public static func reloadHMAC(_ keys: JWTKeyCollection, secret: String) async {
        await keys.add(hmac: .init(from: secret), digestAlgorithm: .sha256)
    }
}
