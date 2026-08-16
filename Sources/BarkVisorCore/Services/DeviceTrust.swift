import Crypto
import Foundation
import X509

/// Trust evaluation for Device↔Device mTLS (PAS-76).
///
/// A peer is accepted when the leaf certificate is **either**
/// issued by this Device's Home CA **or** its SHA-256 fingerprint
/// is in the pairwise pin store **and** the SAN hostId equals `PeerPin.hostId`.
/// Pairing (PAS-45) records pins / issues Home-CA certs; this type only
/// evaluates existing material.
public enum DeviceTrust {
    public static let deviceURIPrefix = "barkvisor://device/"

    public enum Source: String, Sendable, Equatable {
        case homeCA = "home-ca"
        case pinned
    }

    public enum Reason: String, Sendable, Equatable {
        case missingCertificate
        case untrusted
        case expired
        case missingDeviceSAN
        case invalidPEM
    }

    public enum Decision: Sendable, Equatable {
        case accepted(hostId: String, source: Source)
        case rejected(Reason)
    }

    public static func deviceURI(hostId: String) -> String {
        deviceURIPrefix + hostId
    }

    public static func hostId(fromDeviceURI uri: String) -> String? {
        guard uri.hasPrefix(deviceURIPrefix) else { return nil }
        let rest = String(uri.dropFirst(deviceURIPrefix.count))
        return rest.isEmpty ? nil : rest
    }

    public static func fingerprint(der: [UInt8]) -> String {
        SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    public static func fingerprint(certificate: Certificate) throws -> String {
        let der = try certificate.serializeAsPEM().derBytes
        return fingerprint(der: der)
    }

    public static func fingerprint(pem: String) throws -> String {
        let certificate = try Certificate(pemEncoded: pem)
        return try fingerprint(certificate: certificate)
    }

    public static func hostId(from certificate: Certificate) -> String? {
        guard let sans = try? certificate.extensions.subjectAlternativeNames else {
            return nil
        }
        for name in sans {
            if case let .uniformResourceIdentifier(uri) = name,
               let hostId = hostId(fromDeviceURI: uri) {
                return hostId
            }
        }
        return nil
    }

    public static func evaluate(
        leafPEM: String,
        homeCAPEM: String,
        pins: [PeerPin],
        now: Date = Date(),
    ) -> Decision {
        let leaf: Certificate
        do {
            leaf = try Certificate(pemEncoded: leafPEM)
        } catch {
            return .rejected(.invalidPEM)
        }
        return evaluate(leaf: leaf, homeCAPEM: homeCAPEM, pins: pins, now: now)
    }

    public static func evaluate(
        leaf: Certificate,
        homeCAPEM: String,
        pins: [PeerPin],
        now: Date = Date(),
    ) -> Decision {
        if now < leaf.notValidBefore || now > leaf.notValidAfter {
            return .rejected(.expired)
        }

        let fingerprint: String
        do {
            fingerprint = try self.fingerprint(certificate: leaf)
        } catch {
            return .rejected(.invalidPEM)
        }

        let sanHostId = hostId(from: leaf)

        if let pin = pins.first(where: {
            $0.fingerprint.caseInsensitiveCompare(fingerprint) == .orderedSame
        }) {
            guard let hostId = sanHostId else {
                return .rejected(.missingDeviceSAN)
            }
            guard pin.hostId == hostId else {
                return .rejected(.untrusted)
            }
            return .accepted(hostId: hostId, source: .pinned)
        }

        guard let ca = try? Certificate(pemEncoded: homeCAPEM) else {
            return .rejected(.invalidPEM)
        }
        if now < ca.notValidBefore || now > ca.notValidAfter {
            return .rejected(.expired)
        }
        guard isIssuedByHomeCA(leaf: leaf, ca: ca) else {
            return .rejected(.untrusted)
        }
        guard let hostId = sanHostId else {
            return .rejected(.missingDeviceSAN)
        }
        return .accepted(hostId: hostId, source: .homeCA)
    }

    public static func isIssuedByHomeCA(leaf: Certificate, ca: Certificate) -> Bool {
        guard leaf.issuer == ca.subject else { return false }
        return ca.publicKey.isValidSignature(leaf.signature, for: leaf)
    }
}
