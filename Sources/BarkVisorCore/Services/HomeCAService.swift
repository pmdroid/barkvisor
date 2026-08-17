import Crypto
import Foundation
import X509

/// Local Home CA + this Device's leaf certificate (PAS-76).
///
/// Layout (technical plan):
/// ```
/// dataDir/home-ca/ca.crt
/// dataDir/home-ca/ca.key          # 0600
/// dataDir/home-ca/serial
/// dataDir/agent/device.crt
/// dataDir/agent/device.key        # 0600
/// dataDir/agent/ca.crt
/// ```
///
/// Pairing (PAS-45) calls ``issueDeviceCert(hostId:csrPEM:material:)`` to
/// mint peer certs. This ticket only generates the CA, this Device's cert,
/// and the issue primitive.
public enum HomeCAService {
    public static let caDirectoryName = "home-ca"
    public static let agentDirectoryName = "agent"
    public static let caCertificateFileName = "ca.crt"
    public static let caKeyFileName = "ca.key"
    public static let serialFileName = "serial"
    public static let deviceCertificateFileName = "device.crt"
    public static let deviceKeyFileName = "device.key"
    /// Staging dir for atomic Home CA + local leaf rotation.
    public static let rotationDirectoryName = ".rotation"
    public static let rotationReadyFileName = "ready"

    public static let caValidity: TimeInterval = 10 * 365 * 24 * 60 * 60
    public static let deviceValidity: TimeInterval = 365 * 24 * 60 * 60
    /// Reissue a still-valid Device leaf this far before `notValidAfter`.
    public static let deviceRenewalWindow: TimeInterval = 30 * 24 * 60 * 60

    public static func caDirectory(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(caDirectoryName)
    }

    public static func agentDirectory(in dataDir: URL) -> URL {
        dataDir.appendingPathComponent(agentDirectoryName)
    }

    /// Load persisted CA + device cert, or generate both on first start.
    public static func loadOrCreate(dataDir: URL, hostId: String, now: Date = Date()) throws
        -> HomeCertificateMaterial {
        try FileManager.default.createDirectory(
            at: caDirectory(in: dataDir),
            withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: agentDirectory(in: dataDir),
            withIntermediateDirectories: true,
        )
        try completePendingRotation(dataDir: dataDir)

        let ca = try loadOrCreateCA(dataDir: dataDir, now: now)
        let device = try loadOrCreateDeviceCert(dataDir: dataDir, hostId: hostId, ca: ca, now: now)
        try writeAtomic(
            Data(ca.certificatePEM.utf8),
            to: agentDirectory(in: dataDir).appendingPathComponent(caCertificateFileName),
            permissions: 0o644,
        )
        return try HomeCertificateMaterial(
            hostId: hostId,
            caCertificatePEM: ca.certificatePEM,
            caKeyPEM: ca.keyPEM,
            deviceCertificatePEM: device.certificatePEM,
            deviceKeyPEM: device.keyPEM,
            deviceFingerprint: DeviceTrust.fingerprint(pem: device.certificatePEM),
            caFingerprint: DeviceTrust.fingerprint(pem: ca.certificatePEM),
        )
    }

    /// Build a PKCS#10 CSR from this Device's existing key (pairing redeem).
    public static func makeDeviceCSR(hostId: String, keyPEM: String) throws -> String {
        let key = try Certificate.PrivateKey(pemEncoded: keyPEM)
        let subject = try DistinguishedName {
            CommonName(hostId)
        }
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: subject,
            privateKey: key,
            attributes: CertificateSigningRequest.Attributes([]),
        )
        return try csr.serializeAsPEM().pemString
    }

    /// Issue a Device cert signed by this Home CA.
    ///
    /// When `csrPEM` is set, the CSR public key is signed (pairing will send
    /// CSRs). Otherwise a new P-256 key is generated and returned.
    public static func issueDeviceCert(
        hostId: String,
        csrPEM: String? = nil,
        material: HomeCertificateMaterial,
        now: Date = Date(),
        validity: TimeInterval = deviceValidity,
    ) throws -> IssuedDeviceCertificate {
        let caCert = try Certificate(pemEncoded: material.caCertificatePEM)
        let caKey = try Certificate.PrivateKey(pemEncoded: material.caKeyPEM)
        return try issueDeviceCert(
            hostId: hostId,
            csrPEM: csrPEM,
            caCert: caCert,
            caKey: caKey,
            now: now,
            validity: validity,
        )
    }

    /// Issue a Device cert and bump `home-ca/serial` on disk.
    ///
    /// Does **not** rewrite this Device's `agent/device.crt` — `hostId` is the
    /// subject being certified (a peer, after PAS-45).
    public static func issueDeviceCert(
        hostId: String,
        csrPEM: String? = nil,
        dataDir: URL,
        now: Date = Date(),
        validity: TimeInterval = deviceValidity,
    ) throws -> IssuedDeviceCertificate {
        try FileManager.default.createDirectory(
            at: caDirectory(in: dataDir),
            withIntermediateDirectories: true,
        )
        try completePendingRotation(dataDir: dataDir)
        let ca = try loadOrCreateCA(dataDir: dataDir, now: now)
        let issued = try issueDeviceCert(
            hostId: hostId,
            csrPEM: csrPEM,
            caCert: ca.certificate,
            caKey: ca.key,
            now: now,
            validity: validity,
        )
        try incrementSerial(in: dataDir)
        return issued
    }

    // MARK: - Private

    private struct CAFiles {
        let certificatePEM: String
        let keyPEM: String
        let certificate: Certificate
        let key: Certificate.PrivateKey
    }

    private struct DeviceFiles {
        let certificatePEM: String
        let keyPEM: String
    }

    private static func loadOrCreateCA(dataDir: URL, now: Date) throws -> CAFiles {
        let dir = caDirectory(in: dataDir)
        let certURL = dir.appendingPathComponent(caCertificateFileName)
        let keyURL = dir.appendingPathComponent(caKeyFileName)

        let certExists = FileManager.default.fileExists(atPath: certURL.path)
        let keyExists = FileManager.default.fileExists(atPath: keyURL.path)
        if certExists || keyExists {
            let loaded: CAFiles
            do {
                loaded = try loadCA(certURL: certURL, keyURL: keyURL)
            } catch let error as HomeCAError {
                throw error
            } catch {
                throw HomeCAError.corruptMaterial(
                    "unable to load Home CA: \(error.localizedDescription)",
                )
            }
            if isCurrentlyValid(loaded.certificate, now: now) {
                return loaded
            }
            return try rotateCAAndLocalDevice(dataDir: dataDir, now: now)
        }

        return try mintAndPersistCA(dataDir: dataDir, now: now)
    }

    private static func loadCA(certURL: URL, keyURL: URL) throws -> CAFiles {
        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        let cert = try Certificate(pemEncoded: certPEM)
        let key = try Certificate.PrivateKey(pemEncoded: keyPEM)
        guard key.publicKey.isValidSignature(cert.signature, for: cert) else {
            throw HomeCAError.corruptMaterial("ca.key does not match ca.crt")
        }
        return CAFiles(certificatePEM: certPEM, keyPEM: keyPEM, certificate: cert, key: key)
    }

    private static func loadOrCreateDeviceCert(
        dataDir: URL,
        hostId: String,
        ca: CAFiles,
        now: Date,
    ) throws -> DeviceFiles {
        let dir = agentDirectory(in: dataDir)
        let certURL = dir.appendingPathComponent(deviceCertificateFileName)
        let keyURL = dir.appendingPathComponent(deviceKeyFileName)
        let certExists = FileManager.default.fileExists(atPath: certURL.path)
        let keyExists = FileManager.default.fileExists(atPath: keyURL.path)
        if certExists || keyExists {
            let loaded: DeviceFiles
            do {
                loaded = try loadDeviceCert(certURL: certURL, keyURL: keyURL, hostId: hostId, ca: ca)
            } catch let error as HomeCAError {
                throw error
            } catch {
                throw HomeCAError.corruptMaterial(
                    "unable to load device certificate: \(error.localizedDescription)",
                )
            }
            let cert = try Certificate(pemEncoded: loaded.certificatePEM)
            if !certificateNeedsRenewal(cert, now: now, renewalWindow: deviceRenewalWindow) {
                return loaded
            }
        }

        return try mintAndPersistDeviceCert(dataDir: dataDir, hostId: hostId, ca: ca, now: now)
    }

    private static func loadDeviceCert(
        certURL: URL,
        keyURL: URL,
        hostId: String,
        ca: CAFiles,
    ) throws -> DeviceFiles {
        let certPEM = try String(contentsOf: certURL, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        let cert = try Certificate(pemEncoded: certPEM)
        let key = try Certificate.PrivateKey(pemEncoded: keyPEM)
        guard key.publicKey.subjectPublicKeyInfoBytes == cert.publicKey.subjectPublicKeyInfoBytes else {
            throw HomeCAError.corruptMaterial("device.key does not match device.crt")
        }
        guard DeviceTrust.hostId(from: cert) == hostId else {
            throw HomeCAError.corruptMaterial("device.crt SAN does not match hostId")
        }
        guard DeviceTrust.isIssuedByHomeCA(leaf: cert, ca: ca.certificate) else {
            throw HomeCAError.corruptMaterial("device.crt is not issued by Home CA")
        }
        return DeviceFiles(certificatePEM: certPEM, keyPEM: keyPEM)
    }

    private static func issueDeviceCert(
        hostId: String,
        csrPEM: String?,
        caCert: Certificate,
        caKey: Certificate.PrivateKey,
        now: Date,
        validity: TimeInterval = deviceValidity,
    ) throws -> IssuedDeviceCertificate {
        let publicKey: Certificate.PublicKey
        let generatedKeyPEM: String?
        if let csrPEM {
            let csr: CertificateSigningRequest
            do {
                csr = try CertificateSigningRequest(pemEncoded: csrPEM)
            } catch {
                throw HomeCAError.invalidCSR("Unable to parse CSR")
            }
            guard csr.publicKey.isValidSignature(csr.signature, for: csr) else {
                throw HomeCAError.invalidCSR("CSR signature is invalid")
            }
            publicKey = csr.publicKey
            generatedKeyPEM = nil
        } else {
            let key = P256.Signing.PrivateKey()
            let privateKey = Certificate.PrivateKey(key)
            publicKey = privateKey.publicKey
            generatedKeyPEM = try privateKey.serializeAsPEM().pemString
        }

        let subject = try DistinguishedName {
            CommonName(hostId)
        }
        let ski = SubjectKeyIdentifier(hash: publicKey)
        let aki = AuthorityKeyIdentifier(
            keyIdentifier: SubjectKeyIdentifier(hash: caKey.publicKey).keyIdentifier,
        )
        let uri = DeviceTrust.deviceURI(hostId: hostId)
        let eku = try ExtendedKeyUsage([.serverAuth, .clientAuth])
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(validity),
            issuer: caCert.subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                eku
                SubjectAlternativeNames([.uniformResourceIdentifier(uri)])
                ski
                aki
            },
            issuerPrivateKey: caKey,
        )
        let certPEM = try cert.serializeAsPEM().pemString
        return try IssuedDeviceCertificate(
            hostId: hostId,
            certificatePEM: certPEM,
            privateKeyPEM: generatedKeyPEM,
            fingerprint: DeviceTrust.fingerprint(certificate: cert),
            notValidAfter: cert.notValidAfter,
        )
    }

    private static func mintCAInMemory(now: Date) throws -> CAFiles {
        let key = P256.Signing.PrivateKey()
        let privateKey = Certificate.PrivateKey(key)
        let name = try DistinguishedName {
            CommonName("BarkVisor Home CA")
        }
        let ski = SubjectKeyIdentifier(hash: privateKey.publicKey)
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(1),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60),
            notValidAfter: now.addingTimeInterval(caValidity),
            issuer: name,
            subject: name,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
                ski
            },
            issuerPrivateKey: privateKey,
        )
        return try CAFiles(
            certificatePEM: cert.serializeAsPEM().pemString,
            keyPEM: privateKey.serializeAsPEM().pemString,
            certificate: cert,
            key: privateKey,
        )
    }

    private static func mintAndPersistCA(dataDir: URL, now: Date) throws -> CAFiles {
        let created = try mintCAInMemory(now: now)
        try persistCAFiles(created, dataDir: dataDir, serial: 2)
        return created
    }

    /// Mint a replacement Home CA and local leaf, then persist them together.
    /// A crash mid-write is recovered by ``completePendingRotation``.
    private static func rotateCAAndLocalDevice(
        dataDir: URL,
        now: Date,
    ) throws -> CAFiles {
        let created = try mintCAInMemory(now: now)
        let certURL = agentDirectory(in: dataDir)
            .appendingPathComponent(deviceCertificateFileName)
        let device: DeviceFiles?
        if FileManager.default.fileExists(atPath: certURL.path) {
            let certPEM = try String(contentsOf: certURL, encoding: .utf8)
            let cert = try Certificate(pemEncoded: certPEM)
            guard let rotationHostId = DeviceTrust.hostId(from: cert) else {
                throw HomeCAError.corruptMaterial("device.crt SAN missing after Home CA rotation")
            }
            let issued = try issueDeviceCert(
                hostId: rotationHostId,
                csrPEM: nil,
                caCert: created.certificate,
                caKey: created.key,
                now: now,
            )
            guard let keyPEM = issued.privateKeyPEM else {
                throw HomeCAError.persistFailed("Issued local device cert without a private key")
            }
            device = DeviceFiles(certificatePEM: issued.certificatePEM, keyPEM: keyPEM)
        } else {
            device = nil
        }
        try persistRotatedMaterial(dataDir: dataDir, ca: created, device: device)
        return created
    }

    private static func persistCAFiles(_ ca: CAFiles, dataDir: URL, serial: Int) throws {
        let dir = caDirectory(in: dataDir)
        try writeAtomic(
            Data(ca.certificatePEM.utf8),
            to: dir.appendingPathComponent(caCertificateFileName),
            permissions: 0o644,
        )
        try writeAtomic(
            Data(ca.keyPEM.utf8),
            to: dir.appendingPathComponent(caKeyFileName),
            permissions: 0o600,
        )
        try writeAtomic(
            Data("\(serial)".utf8),
            to: dir.appendingPathComponent(serialFileName),
            permissions: 0o644,
        )
    }

    private static func rotationDirectory(in dataDir: URL) -> URL {
        caDirectory(in: dataDir).appendingPathComponent(rotationDirectoryName)
    }

    private static func persistRotatedMaterial(
        dataDir: URL,
        ca: CAFiles,
        device: DeviceFiles?,
    ) throws {
        let staging = rotationDirectory(in: dataDir)
        try? FileManager.default.removeItem(at: staging)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try writeAtomic(
            Data(ca.certificatePEM.utf8),
            to: staging.appendingPathComponent(caCertificateFileName),
            permissions: 0o644,
        )
        try writeAtomic(
            Data(ca.keyPEM.utf8),
            to: staging.appendingPathComponent(caKeyFileName),
            permissions: 0o600,
        )
        let serial = device == nil ? 2 : 3
        try writeAtomic(
            Data("\(serial)".utf8),
            to: staging.appendingPathComponent(serialFileName),
            permissions: 0o644,
        )
        if let device {
            try writeAtomic(
                Data(device.certificatePEM.utf8),
                to: staging.appendingPathComponent(deviceCertificateFileName),
                permissions: 0o644,
            )
            try writeAtomic(
                Data(device.keyPEM.utf8),
                to: staging.appendingPathComponent(deviceKeyFileName),
                permissions: 0o600,
            )
        }
        try writeAtomic(
            Data(),
            to: staging.appendingPathComponent(rotationReadyFileName),
            permissions: 0o644,
        )
        try applyRotationStaging(dataDir: dataDir, staging: staging)
        try? FileManager.default.removeItem(at: staging)
    }

    private static func applyRotationStaging(dataDir: URL, staging: URL) throws {
        let caPEM = try Data(
            contentsOf: staging.appendingPathComponent(caCertificateFileName),
        )
        let caKey = try Data(contentsOf: staging.appendingPathComponent(caKeyFileName))
        let serial = try Data(contentsOf: staging.appendingPathComponent(serialFileName))
        let dir = caDirectory(in: dataDir)
        try writeAtomic(caPEM, to: dir.appendingPathComponent(caCertificateFileName), permissions: 0o644)
        try writeAtomic(caKey, to: dir.appendingPathComponent(caKeyFileName), permissions: 0o600)
        try writeAtomic(serial, to: dir.appendingPathComponent(serialFileName), permissions: 0o644)

        let deviceCertURL = staging.appendingPathComponent(deviceCertificateFileName)
        let deviceKeyURL = staging.appendingPathComponent(deviceKeyFileName)
        if FileManager.default.fileExists(atPath: deviceCertURL.path) {
            let devicePEM = try Data(contentsOf: deviceCertURL)
            let deviceKey = try Data(contentsOf: deviceKeyURL)
            let agent = agentDirectory(in: dataDir)
            try writeAtomic(
                devicePEM,
                to: agent.appendingPathComponent(deviceCertificateFileName),
                permissions: 0o644,
            )
            try writeAtomic(
                deviceKey,
                to: agent.appendingPathComponent(deviceKeyFileName),
                permissions: 0o600,
            )
        }
    }

    static func completePendingRotation(dataDir: URL) throws {
        let staging = rotationDirectory(in: dataDir)
        let ready = staging.appendingPathComponent(rotationReadyFileName)
        guard FileManager.default.fileExists(atPath: ready.path) else {
            if FileManager.default.fileExists(atPath: staging.path) {
                try? FileManager.default.removeItem(at: staging)
            }
            return
        }
        try applyRotationStaging(dataDir: dataDir, staging: staging)
        try? FileManager.default.removeItem(at: staging)
    }

    private static func mintAndPersistDeviceCert(
        dataDir: URL,
        hostId: String,
        ca: CAFiles,
        now: Date,
    ) throws -> DeviceFiles {
        let dir = agentDirectory(in: dataDir)
        let issued = try issueDeviceCert(
            hostId: hostId,
            csrPEM: nil,
            caCert: ca.certificate,
            caKey: ca.key,
            now: now,
        )
        guard let keyPEM = issued.privateKeyPEM else {
            throw HomeCAError.persistFailed("Issued local device cert without a private key")
        }
        try writeAtomic(
            Data(issued.certificatePEM.utf8),
            to: dir.appendingPathComponent(deviceCertificateFileName),
            permissions: 0o644,
        )
        try writeAtomic(
            Data(keyPEM.utf8),
            to: dir.appendingPathComponent(deviceKeyFileName),
            permissions: 0o600,
        )
        try incrementSerial(in: dataDir)
        return DeviceFiles(certificatePEM: issued.certificatePEM, keyPEM: keyPEM)
    }

    static func isExpired(_ certificate: Certificate, now: Date) -> Bool {
        now > certificate.notValidAfter
    }

    static func isCurrentlyValid(_ certificate: Certificate, now: Date) -> Bool {
        now >= certificate.notValidBefore && now <= certificate.notValidAfter
    }

    static func certificateNeedsRenewal(
        _ certificate: Certificate,
        now: Date,
        renewalWindow: TimeInterval,
    ) -> Bool {
        now < certificate.notValidBefore
            || now.addingTimeInterval(renewalWindow) > certificate.notValidAfter
    }

    private static func incrementSerial(in dataDir: URL) throws {
        let url = caDirectory(in: dataDir).appendingPathComponent(serialFileName)
        let current = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 1
        try writeAtomic(Data("\(current + 1)".utf8), to: url, permissions: 0o644)
    }

    private static func writeAtomic(_ data: Data, to url: URL, permissions: Int) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path,
        )
    }
}

public struct HomeCertificateMaterial: Sendable, Equatable {
    public var hostId: String
    public var caCertificatePEM: String
    public var caKeyPEM: String
    public var deviceCertificatePEM: String
    public var deviceKeyPEM: String
    public var deviceFingerprint: String
    public var caFingerprint: String

    public init(
        hostId: String,
        caCertificatePEM: String,
        caKeyPEM: String,
        deviceCertificatePEM: String,
        deviceKeyPEM: String,
        deviceFingerprint: String,
        caFingerprint: String,
    ) {
        self.hostId = hostId
        self.caCertificatePEM = caCertificatePEM
        self.caKeyPEM = caKeyPEM
        self.deviceCertificatePEM = deviceCertificatePEM
        self.deviceKeyPEM = deviceKeyPEM
        self.deviceFingerprint = deviceFingerprint
        self.caFingerprint = caFingerprint
    }
}

public struct IssuedDeviceCertificate: Sendable, Equatable {
    public var hostId: String
    public var certificatePEM: String
    public var privateKeyPEM: String?
    public var fingerprint: String
    public var notValidAfter: Date

    public init(
        hostId: String,
        certificatePEM: String,
        privateKeyPEM: String?,
        fingerprint: String,
        notValidAfter: Date,
    ) {
        self.hostId = hostId
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        self.fingerprint = fingerprint
        self.notValidAfter = notValidAfter
    }
}

public enum HomeCAError: Error, LocalizedError, Sendable, Equatable {
    case invalidCSR(String)
    case persistFailed(String)
    case corruptMaterial(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidCSR(reason): "Invalid certificate signing request: \(reason)"
        case let .persistFailed(reason): "Failed to persist Home CA material: \(reason)"
        case let .corruptMaterial(reason): "Home CA material is corrupt: \(reason)"
        }
    }
}
