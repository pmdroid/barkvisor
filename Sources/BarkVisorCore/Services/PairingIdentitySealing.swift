#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import Foundation
import X509

public enum PairingIdentitySealing {
    static let contextInfo = "barkvisor-pairing-identity-v1"

    public static func seal(
        _ identity: PairingSharedIdentity,
        issuerDeviceKeyPEM: String,
        joinerCertificatePEM: String,
        issuerHostId: String,
        joinerHostId: String,
    ) throws -> PairingIdentitySeal {
        let symmetric = try symmetricKey(
            localKeyPEM: issuerDeviceKeyPEM,
            peerCertificatePEM: joinerCertificatePEM,
            issuerHostId: issuerHostId,
            joinerHostId: joinerHostId,
        )
        let plaintext: Data
        do {
            plaintext = try JSONEncoder().encode(identity)
        } catch {
            throw PairingError.unavailable("Unable to encode pairing identity")
        }
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.seal(plaintext, using: symmetric)
        } catch {
            throw PairingError.unavailable("Unable to seal pairing identity")
        }
        guard let combined = sealed.combined else {
            throw PairingError.unavailable("Unable to seal pairing identity")
        }
        return PairingIdentitySeal(ciphertext: combined.base64EncodedString())
    }

    public static func open(
        _ seal: PairingIdentitySeal,
        joinerDeviceKeyPEM: String,
        issuerCertificatePEM: String,
        issuerHostId: String,
        joinerHostId: String,
    ) throws -> PairingSharedIdentity {
        let symmetric = try symmetricKey(
            localKeyPEM: joinerDeviceKeyPEM,
            peerCertificatePEM: issuerCertificatePEM,
            issuerHostId: issuerHostId,
            joinerHostId: joinerHostId,
        )
        guard let combined = Data(base64Encoded: seal.ciphertext) else {
            throw PairingError.invalidPayload("Pairing identity seal is invalid")
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: combined)
        } catch {
            throw PairingError.invalidPayload("Pairing identity seal is invalid")
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: symmetric)
        } catch {
            throw PairingError.invalidPayload("Pairing identity seal does not match this Device")
        }
        do {
            return try JSONDecoder().decode(PairingSharedIdentity.self, from: plaintext)
        } catch {
            throw PairingError.invalidPayload("Issuer returned an invalid pairing identity")
        }
    }

    private static func symmetricKey(
        localKeyPEM: String,
        peerCertificatePEM: String,
        issuerHostId: String,
        joinerHostId: String,
    ) throws -> SymmetricKey {
        let local: P256.KeyAgreement.PrivateKey
        do {
            local = try P256.KeyAgreement.PrivateKey(pemRepresentation: localKeyPEM)
        } catch {
            throw PairingError.unavailable("Device key is unavailable for pairing identity")
        }
        let peer = try agreementPublicKey(fromCertificatePEM: peerCertificatePEM)
        let shared: SharedSecret
        do {
            shared = try local.sharedSecretFromKeyAgreement(with: peer)
        } catch {
            throw PairingError.invalidPayload("Pairing identity key agreement failed")
        }
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data((issuerHostId + joinerHostId).utf8),
            sharedInfo: Data(contextInfo.utf8),
            outputByteCount: 32,
        )
    }

    private static func agreementPublicKey(fromCertificatePEM pem: String) throws
        -> P256.KeyAgreement.PublicKey {
        let certificate: Certificate
        do {
            certificate = try Certificate(pemEncoded: pem)
        } catch {
            throw PairingError.invalidDeviceCertificate("Unable to parse pairing certificate")
        }
        guard let signing = P256.Signing.PublicKey(certificate.publicKey) else {
            throw PairingError.invalidDeviceCertificate(
                "Pairing certificate key is not P-256",
            )
        }
        return try P256.KeyAgreement.PublicKey(x963Representation: signing.x963Representation)
    }
}
