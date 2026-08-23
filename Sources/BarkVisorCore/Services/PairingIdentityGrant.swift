import Foundation

/// Short-lived grant so shared login is readable only after a current redeem
/// (PAS-283). Bound to the joining Device's issued cert and the offer TTL.
public struct PairingIdentityGrant: Codable, Sendable, Equatable {
    public var hostId: String
    public var fingerprint: String
    public var expiresAt: String

    public init(hostId: String, fingerprint: String, expiresAt: String) {
        self.hostId = hostId
        self.fingerprint = fingerprint
        self.expiresAt = expiresAt
    }
}

extension PairingService {
    public static let identityGrantFileName = "pairing-identity-grant.json"

    public static func identityGrantURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(identityGrantFileName)
    }

    public static func persistIdentityGrant(
        dataDir: URL,
        hostId: String,
        fingerprint: String,
        expiresAt: String,
    ) throws {
        let grant = PairingIdentityGrant(
            hostId: hostId,
            fingerprint: fingerprint.lowercased(),
            expiresAt: expiresAt,
        )
        let url = identityGrantURL(in: dataDir)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            let data = try JSONEncoder().encode(grant)
            try data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path,
            )
        } catch {
            throw PairingError.unavailable(
                "Unable to persist pairing identity grant: \(error.localizedDescription)",
            )
        }
    }

    public static func loadIdentityGrant(dataDir: URL) throws -> PairingIdentityGrant? {
        let url = identityGrantURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PairingError.unavailable(
                "Unable to read pairing identity grant: \(error.localizedDescription)",
            )
        }
        do {
            return try JSONDecoder().decode(PairingIdentityGrant.self, from: data)
        } catch {
            throw PairingError.unavailable(
                "Unable to decode pairing identity grant: \(error.localizedDescription)",
            )
        }
    }

    public static func clearIdentityGrant(dataDir: URL) throws {
        let url = identityGrantURL(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw PairingError.unavailable(
                "Unable to clear pairing identity grant: \(error.localizedDescription)",
            )
        }
    }

    /// Shared login is readable only by the Device that just redeemed, until
    /// the pairing offer expires. Any other Home-CA peer is denied.
    public static func authorizeIdentityRead(
        dataDir: URL,
        hostId: String,
        fingerprint: String,
        now: Date = Date(),
    ) throws {
        guard let grant = try loadIdentityGrant(dataDir: dataDir) else {
            throw PairingError.identityNotGranted
        }
        if let expires = iso8601.date(from: grant.expiresAt), now >= expires {
            throw PairingError.identityNotGranted
        }
        let peerHost = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerFingerprint = fingerprint.lowercased()
        guard grant.hostId == peerHost, grant.fingerprint == peerFingerprint else {
            throw PairingError.identityNotGranted
        }
    }
}
