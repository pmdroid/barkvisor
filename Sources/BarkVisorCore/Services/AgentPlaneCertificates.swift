import Foundation
import X509

/// Agent-plane certs after pairing (PAS-34 / PAS-45).
///
/// Join persists an issued Device cert in `pairing-peer.json` but does not
/// replace local Home CA files. The agent listener and mTLS client must
/// still present that issued leaf (same `device.key`) and trust the
/// issuer Home CA, or two Homes cannot verify each other.
public enum AgentPlaneCertificates {
    public enum PresentationError: Error, LocalizedError {
        case issuedCertificateDoesNotMatchDeviceKey

        public var errorDescription: String? {
            "Pairing-issued certificate does not match the persisted device key"
        }
    }
    /// Leaf to present on 7778 / as the mTLS client cert.
    /// Prefers the pairing-issued cert when it matches `device.key`.
    public static func presentationCertificatePEM(
        material: HomeCertificateMaterial,
        receipt: PairingPeerReceipt?,
    ) throws -> String {
        guard let receipt else { return material.deviceCertificatePEM }
        guard certificateMatchesKey(receipt.issuedCertificatePEM, keyPEM: material.deviceKeyPEM) else {
            throw PresentationError.issuedCertificateDoesNotMatchDeviceKey
        }
        return receipt.issuedCertificatePEM
    }

    /// Trust roots for verifying a peer's agent cert.
    /// Always includes this Device's Home CA; adds the paired issuer CA.
    public static func trustCertificatePEMs(
        material: HomeCertificateMaterial,
        receipt: PairingPeerReceipt?,
    ) -> [String] {
        var pems = [material.caCertificatePEM]
        if let receipt,
           receipt.caFingerprint.lowercased() != material.caFingerprint.lowercased() {
            pems.append(receipt.caCertificatePEM)
        }
        return pems
    }

    public static func certificateMatchesKey(_ certificatePEM: String, keyPEM: String) -> Bool {
        do {
            let cert = try Certificate(pemEncoded: certificatePEM)
            let key = try Certificate.PrivateKey(pemEncoded: keyPEM)
            return key.publicKey.subjectPublicKeyInfoBytes == cert.publicKey.subjectPublicKeyInfoBytes
        } catch {
            return false
        }
    }
}
