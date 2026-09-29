import Foundation
import JWTKit

extension HomeMemberHop {
    static func preserveLegacyJWTSecret(dataDir: URL) throws {
        guard var receipt = try PairingService.loadReceipt(dataDir: dataDir),
              receipt.legacyJWTSecret == nil,
              let secret = Config.loadJWTSecret(from: dataDir), !secret.isEmpty
        else { return }
        receipt.legacyJWTSecret = secret
        try PairingService.persistReceipt(receipt, dataDir: dataDir)
    }

    public static func localLegacyToken(
        dataDir: URL,
        localHostId: String,
        peerHostId: String,
        peerCertificatePEM: String,
        token: String,
        now: Date = Date(),
    ) async throws -> String {
        let fingerprint = try DeviceTrust.fingerprint(pem: peerCertificatePEM)
        guard let receipt = try PairingService.loadReceipt(dataDir: dataDir),
              receipt.peerHostId.caseInsensitiveCompare(peerHostId) == .orderedSame,
              receipt.peerFingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame,
              case .allow = HomeMembershipAuthority(dataDir: dataDir).authorizeCertificate(
                  hostId: peerHostId,
                  fingerprint: fingerprint,
                  localHostId: localHostId,
                  now: now,
              ),
              let secret = receipt.legacyJWTSecret ?? Config.loadJWTSecret(from: dataDir),
              !secret.isEmpty
        else {
            throw BarkVisorError.unauthorized("Legacy credential is not bound to the paired Home")
        }
        let legacyKeys = JWTKeyCollection()
        await legacyKeys.add(hmac: .init(from: secret), digestAlgorithm: .sha256)
        let payload: UserPayload
        do {
            payload = try await legacyKeys.verify(token, as: UserPayload.self)
        } catch {
            throw BarkVisorError.unauthorized("Invalid or expired legacy Home credential")
        }
        let remaining = payload.exp.value.timeIntervalSince(now)
        guard remaining > 0, remaining <= AuthService.memberHopTokenTTL + 60 else {
            throw BarkVisorError.unauthorized("Legacy Home credential must be short-lived")
        }
        guard let localSecret = Config.loadJWTSecret(from: dataDir), !localSecret.isEmpty else {
            throw BarkVisorError.internalError("Local session key is unavailable")
        }
        if receipt.legacyJWTSecret == nil {
            try preserveLegacyJWTSecret(dataDir: dataDir)
        }
        let localKeys = JWTKeyCollection()
        await localKeys.add(hmac: .init(from: localSecret), digestAlgorithm: .sha256)
        return try await localKeys.sign(payload)
    }
}
