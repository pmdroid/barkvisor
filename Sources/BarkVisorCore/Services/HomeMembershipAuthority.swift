import Crypto
import Foundation
import X509

public enum HomeMembershipPolicy {
    public static let maximumStaleAuthorizationWindow: TimeInterval = 24 * 60 * 60
    public static let managePermission = "manage"
}

public enum MembershipWriter: String, Sendable {
    case daemon
    case publicServer
}

public enum HomeMembershipDecision: Equatable, Sendable {
    case allow
    case deny(String)
}

public struct HomeMemberRecord: Codable, Equatable, Sendable {
    public var hostId: String
    public var status: String
    public var keyFingerprints: [String]
    public var permissions: [String]
    public var exchangeId: String?
    public var revision: Int

    public init(
        hostId: String,
        status: String,
        keyFingerprints: [String],
        permissions: [String],
        exchangeId: String?,
        revision: Int,
    ) {
        self.hostId = hostId
        self.status = status
        self.keyFingerprints = keyFingerprints
        self.permissions = permissions
        self.exchangeId = exchangeId
        self.revision = revision
    }
}

public struct HomeMembershipLedger: Codable, Equatable, Sendable {
    public var revision: Int
    public var lastSnapshotAt: TimeInterval
    public var sharedSigningMaterialRetired: Bool
    public var members: [HomeMemberRecord]

    public init(
        revision: Int,
        lastSnapshotAt: TimeInterval,
        sharedSigningMaterialRetired: Bool,
        members: [HomeMemberRecord],
    ) {
        self.revision = revision
        self.lastSnapshotAt = lastSnapshotAt
        self.sharedSigningMaterialRetired = sharedSigningMaterialRetired
        self.members = members
    }
}

public struct HomeMembershipSnapshot: Codable, Equatable, Sendable {
    public var revision: Int
    public var exportedAt: TimeInterval
    public var signerHostId: String
    public var signerCertificatePEM: String
    public var members: [HomeMemberRecord]
    public var signature: String

    public init(
        revision: Int,
        exportedAt: TimeInterval,
        signerHostId: String,
        signerCertificatePEM: String,
        members: [HomeMemberRecord],
        signature: String,
    ) {
        self.revision = revision
        self.exportedAt = exportedAt
        self.signerHostId = signerHostId
        self.signerCertificatePEM = signerCertificatePEM
        self.members = members
        self.signature = signature
    }
}

public enum MembershipProcessBoundary {
    public static let authorityRelativePaths = [
        "authority/management.key",
        "home-ca/ca.key",
        "jwt-secret",
        "api-key-hmac-secret",
        "agent/membership.json",
    ]
    public static let serverRelativePaths = [
        "agent/device.crt",
        "agent/device.key",
        "agent/ca.crt",
        "home-ca/ca.crt",
        "authority/management.pub",
    ]

    public static var transportsAndAuthorityAreDisjoint: Bool {
        Set(authorityRelativePaths).isDisjoint(with: serverRelativePaths)
    }

    public static func canMintManagementCredential(readableRelativePaths: [String]) -> Bool {
        readableRelativePaths.contains("authority/management.key")
    }
}

public enum ForwardedIdentity {
    public static let headerNames = [
        "x-barkvisor-host-id",
        "x-barkvisor-user",
        "x-forwarded-user",
    ]

    public static func rejects(headerNames presented: [String]) -> Bool {
        let lowered = Set(presented.map { $0.lowercased() })
        return !lowered.isDisjoint(with: Set(headerNames))
    }
}

public enum LocalWorkloadPolicy {
    public static func keepsRunning(membershipAuthorityReachable: Bool) -> Bool {
        _ = membershipAuthorityReachable
        return true
    }
}

public actor PrivilegedStreamGate {
    public static let shared = PrivilegedStreamGate()

    private struct Stream {
        var memberHostId: String
        var close: @Sendable () -> Void
    }

    private var streams: [UUID: Stream] = [:]

    public func register(
        memberHostId: String,
        close: @escaping @Sendable () -> Void,
    ) -> UUID {
        let id = UUID()
        streams[id] = Stream(memberHostId: memberHostId, close: close)
        return id
    }

    public func end(_ id: UUID) {
        streams.removeValue(forKey: id)
    }

    @discardableResult
    public func invalidate(memberHostId: String) -> [UUID] {
        let matches = streams.filter {
            $0.value.memberHostId.caseInsensitiveCompare(memberHostId) == .orderedSame
        }
        for (id, stream) in matches {
            streams.removeValue(forKey: id)
            stream.close()
        }
        return Array(matches.keys)
    }
}

public final class HomeMembershipAuthority: @unchecked Sendable {
    public static let fileName = "membership.json"
    public static let managementDirectoryName = "authority"
    public static let managementKeyFileName = "management.key"
    public static let managementPublicKeyFileName = "management.pub"

    public let dataDir: URL
    private let lock = NSLock()

    public init(dataDir: URL) {
        self.dataDir = dataDir
    }

    public static func ledgerExists(dataDir: URL) -> Bool {
        FileManager.default.fileExists(atPath: ledgerURL(in: dataDir).path)
    }

    public static func ledgerURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(fileName)
    }

    public static func managementKeyURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(managementDirectoryName)
            .appendingPathComponent(managementKeyFileName)
    }

    public static func managementPublicKeyURL(in dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent(managementDirectoryName)
            .appendingPathComponent(managementPublicKeyFileName)
    }

    public static func migrateExistingHome(
        dataDir: URL,
        localHostId: String,
        now: Date = Date(),
        devices: DeviceRegistry? = nil,
        pins: PeerPinStore? = nil,
    ) throws {
        let authority = HomeMembershipAuthority(dataDir: dataDir)
        try authority.migrate(
            localHostId: localHostId,
            now: now,
            devices: devices,
            pins: pins,
        )
    }

    public func currentRevision() throws -> Int {
        try load().revision
    }

    public func load() throws -> HomeMembershipLedger {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    @discardableResult
    public func beginAdmission(
        exchangeId: String,
        hostId: String,
        fingerprint: String,
        now: Date = Date(),
        writer: MembershipWriter = .daemon,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        let exchange = exchangeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalize(hostId)
        let key = fingerprint.lowercased()
        guard !exchange.isEmpty, !target.isEmpty, !key.isEmpty else {
            throw BarkVisorError.badRequest("Pairing exchange, Device id, and key are required")
        }
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        if let index = index(of: target, in: ledger.members) {
            let existing = ledger.members[index]
            if existing.status == "removed", existing.exchangeId == exchange {
                throw BarkVisorError.forbidden(
                    "Removed membership cannot be restored by retrying the old pairing exchange",
                )
            }
            if existing.status == "active",
               existing.exchangeId == exchange,
               existing.keyFingerprints.contains(key) {
                return ledger
            }
        }
        ledger.revision += 1
        let record = HomeMemberRecord(
            hostId: target,
            status: "pending",
            keyFingerprints: [key],
            permissions: [HomeMembershipPolicy.managePermission],
            exchangeId: exchange,
            revision: ledger.revision,
        )
        if let index = index(of: target, in: ledger.members) {
            ledger.members[index] = record
        } else {
            ledger.members.append(record)
        }
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try persistLocked(ledger)
        return ledger
    }

    @discardableResult
    public func commitAdmission(
        exchangeId: String,
        hostId: String,
        fingerprint: String,
        now: Date = Date(),
        writer: MembershipWriter = .daemon,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        let exchange = exchangeId.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = normalize(hostId)
        let key = fingerprint.lowercased()
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        guard let index = index(of: target, in: ledger.members) else {
            throw BarkVisorError.forbidden("Pairing has no pending membership")
        }
        let pending = ledger.members[index]
        guard pending.status == "pending" || pending.status == "active" else {
            throw BarkVisorError.forbidden("Removed membership cannot be restored by committing an old exchange")
        }
        // The record also carries the leaves the Home issued for this Device,
        // so the exchange only has to be bound to the key that was presented.
        guard pending.exchangeId == exchange, pending.keyFingerprints.contains(key) else {
            throw BarkVisorError.forbidden("Pairing exchange is not bound to this Device key")
        }
        if pending.status == "active" {
            return ledger
        }
        ledger.revision += 1
        ledger.members[index].status = "active"
        ledger.members[index].revision = ledger.revision
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try persistLocked(ledger)
        return ledger
    }

    public func abortAdmission(
        hostId: String,
        exchangeId: String,
        writer: MembershipWriter = .daemon,
    ) throws {
        try requireDaemon(writer)
        let target = normalize(hostId)
        let exchange = exchangeId.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: Date())
        guard let index = index(of: target, in: ledger.members) else { return }
        let record = ledger.members[index]
        guard record.status == "pending", record.exchangeId == exchange else { return }
        ledger.members.remove(at: index)
        ledger.revision += 1
        try persistLocked(ledger)
    }

    public func removeMember(
        hostId: String,
        localHostId: String,
        now: Date = Date(),
        devices: DeviceRegistry? = nil,
        pins: PeerPinStore? = nil,
        writer: MembershipWriter = .daemon,
    ) throws {
        try requireDaemon(writer)
        let target = normalize(hostId)
        guard !target.isEmpty else {
            throw BarkVisorError.badRequest("Device id is required")
        }
        guard target.caseInsensitiveCompare(localHostId) != .orderedSame else {
            throw BarkVisorError.forbidden("This Device cannot remove itself from the Home")
        }
        let directory = devices ?? DeviceRegistry(dataDir: dataDir)
        let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
        lock.lock()
        defer { lock.unlock() }
        _ = try directory.load()
        _ = try pinStore.load()
        var ledger = try loadOrEmptyLocked(now: now)
        let existing = index(of: target, in: ledger.members).map { ledger.members[$0] }
        let pinned = try pinStore.pin(forHostId: target)?.fingerprint
        let fingerprints = existing?.keyFingerprints ?? [pinned].compactMap(\.self)
        ledger.revision += 1
        let removed = HomeMemberRecord(
            hostId: target,
            status: "removed",
            keyFingerprints: fingerprints,
            permissions: [],
            exchangeId: existing?.exchangeId,
            revision: ledger.revision,
        )
        if let index = index(of: target, in: ledger.members) {
            ledger.members[index] = removed
        } else {
            ledger.members.append(removed)
        }
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try pinStore.unpin(hostId: target)
        try directory.remove(hostId: target)
        try persistLocked(ledger)
    }

    @discardableResult
    public func rotateDeviceKey(
        hostId: String,
        newFingerprint: String,
        now: Date = Date(),
        writer: MembershipWriter = .daemon,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        let target = normalize(hostId)
        let key = newFingerprint.lowercased()
        guard !key.isEmpty else {
            throw BarkVisorError.badRequest("Device key is required")
        }
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        guard let index = index(of: target, in: ledger.members) else {
            throw BarkVisorError.forbidden("Unknown Device cannot rotate a Home key")
        }
        guard ledger.members[index].status == "active" else {
            throw BarkVisorError.forbidden("Removed membership cannot be restored by key rotation")
        }
        ledger.revision += 1
        ledger.members[index].keyFingerprints = [key]
        ledger.members[index].revision = ledger.revision
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try persistLocked(ledger)
        return ledger
    }

    /// Whole-certificate fingerprints this member may present, in the order
    /// the Home admitted them. Index 0 is the certificate the member presented
    /// at pairing; later entries are the leaves the Home issued for it.
    public func memberFingerprints(hostId: String) throws -> [String] {
        let target = normalize(hostId)
        let ledger = try load()
        guard let index = index(of: target, in: ledger.members) else {
            throw BarkVisorError.forbidden("Unknown Device is not a Home member")
        }
        return ledger.members[index].keyFingerprints
    }

    /// Admit exactly `fingerprints` for a member: the ledger record and the
    /// pin store move to that set in one locked step.
    ///
    /// Pins are written first because a stale pin set is the safe direction —
    /// it can only under-authorize — while a stale ledger could admit a
    /// certificate the Home no longer pins. Pairing uses this to record the
    /// certificate the member brought *and* the one the Home issued for it.
    @discardableResult
    public func admitMemberCertificate(
        hostId: String,
        fingerprints: [String],
        now: Date = Date(),
        pins: PeerPinStore? = nil,
        writer: MembershipWriter = .daemon,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        let target = normalize(hostId)
        let wanted = orderedUnique(fingerprints)
        guard !target.isEmpty, !wanted.isEmpty else {
            throw BarkVisorError.badRequest("Device id and certificate fingerprint are required")
        }
        let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        let position = try memberIndex(target, in: ledger)
        return try applyFingerprintsLocked(
            wanted,
            hostId: target,
            ledger: &ledger,
            index: position,
            now: now,
            pinStore: pinStore,
        )
    }

    /// Swap the leaf a member presents for a freshly issued one.
    ///
    /// The previous leaf stays admitted so a renewal whose response was lost
    /// can be retried with it; older leaves are dropped once the cap is hit
    /// (``HomeCertificateRenewal/admittedFingerprints(previous:superseding:issued:maximum:)``).
    /// Read and both writes happen under one lock, so two overlapping
    /// renewals cannot leave the member holding a certificate the Home no
    /// longer admits.
    @discardableResult
    public func renewMemberCertificate(
        hostId: String,
        superseding: String,
        issued: String,
        now: Date = Date(),
        pins: PeerPinStore? = nil,
        writer: MembershipWriter = .daemon,
        maximumAdmitted: Int = HomeCertificateRenewal.admittedFingerprintsPerMember,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        let target = normalize(hostId)
        let replacement = issued.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !target.isEmpty, !replacement.isEmpty else {
            throw BarkVisorError.badRequest("Device id and certificate fingerprint are required")
        }
        let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        let position = try memberIndex(target, in: ledger)
        let wanted = HomeCertificateRenewal.admittedFingerprints(
            previous: ledger.members[position].keyFingerprints,
            superseding: superseding,
            issued: replacement,
            maximum: max(1, maximumAdmitted),
        )
        return try applyFingerprintsLocked(
            wanted,
            hostId: target,
            ledger: &ledger,
            index: position,
            now: now,
            pinStore: pinStore,
        )
    }

    /// Caller holds `lock`.
    private func memberIndex(_ hostId: String, in ledger: HomeMembershipLedger) throws -> Int {
        guard let position = index(of: hostId, in: ledger.members) else {
            throw BarkVisorError.forbidden("Unknown Device cannot present a Home certificate")
        }
        let status = ledger.members[position].status
        guard status == "active" || status == "pending" else {
            throw BarkVisorError.forbidden("Removed member cannot renew a Home certificate")
        }
        return position
    }

    /// Caller holds `lock`. Pins land first: a pin set that lags membership can
    /// only under-authorize, and every fingerprint in `wanted` is already
    /// proven at this point.
    private func applyFingerprintsLocked(
        _ wanted: [String],
        hostId: String,
        ledger: inout HomeMembershipLedger,
        index: Int,
        now: Date,
        pinStore: PeerPinStore,
    ) throws -> HomeMembershipLedger {
        ledger.revision += 1
        ledger.members[index].keyFingerprints = wanted
        ledger.members[index].revision = ledger.revision
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try pinStore.set(hostId: hostId, fingerprints: wanted, now: now)
        try persistLocked(ledger)
        return ledger
    }

    private func orderedUnique(_ fingerprints: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in fingerprints {
            let fingerprint = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !fingerprint.isEmpty, seen.insert(fingerprint).inserted else { continue }
            result.append(fingerprint)
        }
        return result
    }

    public func authorizeCertificate(
        hostId: String,
        fingerprint: String,
        localHostId: String? = nil,
        now _: Date = Date(),
    ) -> HomeMembershipDecision {
        if let localHostId, hostId.caseInsensitiveCompare(localHostId) == .orderedSame {
            return .allow
        }
        guard Self.ledgerExists(dataDir: dataDir) else {
            return .allow
        }
        do {
            let ledger = try load()
            return decideCertificate(
                ledger: ledger,
                hostId: hostId,
                fingerprint: fingerprint,
            )
        } catch {
            return .deny("Membership ledger is unreadable")
        }
    }

    public func authorizeLoginToken(
        issuerHostId: String,
        subjectHostId: String?,
        issuedAt: Date,
        expiresAt: Date,
        membershipRevision: Int,
        localHostId: String,
        now: Date = Date(),
    ) -> HomeMembershipDecision {
        if expiresAt <= issuedAt
            || expiresAt.timeIntervalSince(issuedAt) > HomeMembershipPolicy.maximumStaleAuthorizationWindow
            || now >= expiresAt {
            return .deny("Login token is outside its authorization window")
        }
        guard Self.ledgerExists(dataDir: dataDir) else {
            return .allow
        }
        do {
            let ledger = try load()
            if let subjectHostId, subjectHostId.caseInsensitiveCompare(localHostId) != .orderedSame {
                if let member = member(subjectHostId, in: ledger), member.status == "removed" {
                    return .deny("Removed member login token")
                }
            }
            if issuerHostId.caseInsensitiveCompare(localHostId) == .orderedSame {
                return .allow
            }
            guard let member = member(issuerHostId, in: ledger) else {
                return .deny("Login token issuer is not a Home member")
            }
            if member.status != "active" {
                return .deny("Removed member login token")
            }
            if now.timeIntervalSince1970 > ledger.lastSnapshotAt
                + HomeMembershipPolicy.maximumStaleAuthorizationWindow {
                return .deny("Membership snapshot is stale")
            }
            return .allow
        } catch {
            return .deny("Membership ledger is unreadable")
        }
    }

    public func authorizeProxy(
        callerHostId: String?,
        targetHostId: String,
        fingerprint: String?,
        localHostId: String,
        now: Date = Date(),
    ) -> HomeMembershipDecision {
        if targetHostId.caseInsensitiveCompare(localHostId) == .orderedSame {
            return .allow
        }
        guard Self.ledgerExists(dataDir: dataDir) else {
            return .allow
        }
        do {
            let ledger = try load()
            if let callerHostId,
               callerHostId.caseInsensitiveCompare(localHostId) != .orderedSame,
               let caller = member(callerHostId, in: ledger),
               caller.status == "removed" {
                return .deny("Removed member cannot proxy")
            }
            guard let target = member(targetHostId, in: ledger) else {
                return .deny("Proxy target is not a Home member")
            }
            if target.status != "active" {
                return .deny("Removed member cannot be proxied")
            }
            if let fingerprint,
               !target.keyFingerprints.contains(where: {
                   $0.caseInsensitiveCompare(fingerprint) == .orderedSame
               }) {
                return .deny("Proxy target key does not match membership")
            }
            if now.timeIntervalSince1970 > ledger.lastSnapshotAt
                + HomeMembershipPolicy.maximumStaleAuthorizationWindow {
                return .deny("Membership snapshot is stale")
            }
            return .allow
        } catch {
            return .deny("Membership ledger is unreadable")
        }
    }

    public func authorizeLocalWorkload(membershipAuthorityReachable: Bool) -> HomeMembershipDecision {
        if LocalWorkloadPolicy.keepsRunning(
            membershipAuthorityReachable: membershipAuthorityReachable,
        ) {
            return .allow
        }
        return .deny("Local Workload policy refused")
    }

    public func signedSnapshot(
        signerHostId: String,
        deviceCertificatePEM: String,
        deviceKeyPEM: String,
        now: Date = Date(),
    ) throws -> HomeMembershipSnapshot {
        let ledger = try load()
        let members = ledger.members.sorted { $0.hostId < $1.hostId }
        let unsigned = UnsignedSnapshot(
            revision: ledger.revision,
            exportedAt: now.timeIntervalSince1970,
            signerHostId: signerHostId,
            signerCertificatePEM: deviceCertificatePEM,
            members: members,
        )
        let data = try canonical(unsigned)
        let key = try P256.Signing.PrivateKey(pemRepresentation: deviceKeyPEM)
        let signature = try key.signature(for: data)
        return HomeMembershipSnapshot(
            revision: unsigned.revision,
            exportedAt: unsigned.exportedAt,
            signerHostId: unsigned.signerHostId,
            signerCertificatePEM: unsigned.signerCertificatePEM,
            members: unsigned.members,
            signature: signature.derRepresentation.base64EncodedString(),
        )
    }

    @discardableResult
    public func importSnapshot(
        _ snapshot: HomeMembershipSnapshot,
        now: Date = Date(),
        writer: MembershipWriter = .daemon,
    ) throws -> HomeMembershipLedger {
        try requireDaemon(writer)
        try verifySnapshot(snapshot)
        lock.lock()
        defer { lock.unlock() }
        var ledger = try loadOrEmptyLocked(now: now)
        if let signer = member(snapshot.signerHostId, in: ledger), signer.status == "removed" {
            throw BarkVisorError.forbidden("Removed member cannot publish membership")
        }
        guard snapshot.revision >= ledger.revision else {
            return ledger
        }
        for remote in snapshot.members where remote.status == "removed" {
            if let index = index(of: remote.hostId, in: ledger.members) {
                if ledger.members[index].status != "removed" {
                    ledger.members[index].status = "removed"
                    ledger.members[index].permissions = []
                    ledger.members[index].revision = snapshot.revision
                }
            } else {
                ledger.members.append(
                    HomeMemberRecord(
                        hostId: normalize(remote.hostId),
                        status: "removed",
                        keyFingerprints: remote.keyFingerprints.map { $0.lowercased() },
                        permissions: [],
                        exchangeId: remote.exchangeId,
                        revision: snapshot.revision,
                    ),
                )
            }
        }
        ledger.revision = snapshot.revision
        ledger.lastSnapshotAt = now.timeIntervalSince1970
        try persistLocked(ledger)
        return ledger
    }

    public func managementKeyPEM(writer: MembershipWriter = .daemon) throws -> String {
        try requireDaemon(writer)
        let url = Self.managementKeyURL(in: dataDir)
        if let existing = try? String(contentsOf: url, encoding: .utf8), existing.contains("PRIVATE") {
            return existing
        }
        let key = P256.Signing.PrivateKey()
        let pem = key.pemRepresentation
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(pem.utf8).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path,
        )
        let publicPEM = key.publicKey.pemRepresentation
        let publicURL = Self.managementPublicKeyURL(in: dataDir)
        try Data(publicPEM.utf8).write(to: publicURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: publicURL.path,
        )
        return pem
    }

    public func managementPublicKeyPEM() throws -> String {
        let url = Self.managementPublicKeyURL(in: dataDir)
        guard let pem = try? String(contentsOf: url, encoding: .utf8), pem.contains("PUBLIC") else {
            throw BarkVisorError.unauthorized("Management credential issuer is not available")
        }
        return pem
    }

    private func migrate(
        localHostId: String,
        now: Date,
        devices: DeviceRegistry?,
        pins: PeerPinStore?,
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        var ledger: HomeMembershipLedger
        if FileManager.default.fileExists(atPath: Self.ledgerURL(in: dataDir).path) {
            ledger = try loadLocked()
        } else {
            let directory = devices ?? DeviceRegistry(dataDir: dataDir)
            let pinStore = pins ?? PeerPinStore(dataDir: dataDir)
            let pinRows = try pinStore.load()
            let deviceRows = try directory.load()
            var members: [HomeMemberRecord] = []
            var seen: Set<String> = []
            for pin in pinRows where pin.hostId.caseInsensitiveCompare(localHostId) != .orderedSame {
                let hostId = normalize(pin.hostId)
                seen.insert(hostId.lowercased())
                members.append(
                    HomeMemberRecord(
                        hostId: hostId,
                        status: "active",
                        keyFingerprints: [pin.fingerprint.lowercased()],
                        permissions: [HomeMembershipPolicy.managePermission],
                        exchangeId: nil,
                        revision: 1,
                    ),
                )
            }
            for row in deviceRows where row.hostId.caseInsensitiveCompare(localHostId) != .orderedSame {
                let hostId = normalize(row.hostId)
                if seen.contains(hostId.lowercased()) { continue }
                members.append(
                    HomeMemberRecord(
                        hostId: hostId,
                        status: "active",
                        keyFingerprints: [row.fingerprint.lowercased()],
                        permissions: [HomeMembershipPolicy.managePermission],
                        exchangeId: nil,
                        revision: 1,
                    ),
                )
            }
            ledger = HomeMembershipLedger(
                revision: members.isEmpty ? 0 : 1,
                lastSnapshotAt: now.timeIntervalSince1970,
                sharedSigningMaterialRetired: false,
                members: members,
            )
        }
        if !ledger.sharedSigningMaterialRetired {
            let joined = PairingService.hasPairedReceipt(dataDir: dataDir) || !ledger.members.isEmpty
            if joined, Config.loadJWTSecret(from: dataDir) != nil {
                try HomeMemberHop.preserveLegacyJWTSecret(dataDir: dataDir)
                let secret = PlatformRandom.secureBase64(byteCount: 32)
                try Config.persistJWTSecret(secret, to: dataDir)
            }
            ledger.sharedSigningMaterialRetired = true
            ledger.lastSnapshotAt = now.timeIntervalSince1970
            try persistLocked(ledger)
        }
    }

    private func decideCertificate(
        ledger: HomeMembershipLedger,
        hostId: String,
        fingerprint: String,
    ) -> HomeMembershipDecision {
        guard let record = member(hostId, in: ledger) else {
            return .deny("Certificate is not a committed Home member")
        }
        if record.status == "pending" {
            return .deny("Pairing is not a committed membership")
        }
        if record.status != "active" {
            return .deny("Removed member certificate")
        }
        guard record.keyFingerprints.contains(where: {
            $0.caseInsensitiveCompare(fingerprint) == .orderedSame
        }) else {
            return .deny("Certificate key is not the admitted Device key")
        }
        return .allow
    }

    private func verifySnapshot(_ snapshot: HomeMembershipSnapshot) throws {
        let unsigned = UnsignedSnapshot(
            revision: snapshot.revision,
            exportedAt: snapshot.exportedAt,
            signerHostId: snapshot.signerHostId,
            signerCertificatePEM: snapshot.signerCertificatePEM,
            members: snapshot.members,
        )
        let data = try canonical(unsigned)
        let certificate = try Certificate(pemEncoded: snapshot.signerCertificatePEM)
        guard DeviceTrust.hostId(from: certificate)?.caseInsensitiveCompare(snapshot.signerHostId)
            == .orderedSame
        else {
            throw BarkVisorError.forbidden("Membership snapshot signer does not match the certificate")
        }
        guard let publicKey = P256.Signing.PublicKey(certificate.publicKey) else {
            throw BarkVisorError.forbidden("Membership snapshot signer is not a Device key")
        }
        guard let signatureData = Data(base64Encoded: snapshot.signature) else {
            throw BarkVisorError.forbidden("Membership snapshot signature is invalid")
        }
        let signature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
        guard publicKey.isValidSignature(signature, for: data) else {
            throw BarkVisorError.forbidden("Membership snapshot signature is invalid")
        }
    }

    private func requireDaemon(_ writer: MembershipWriter) throws {
        guard writer == .daemon else {
            throw BarkVisorError.forbidden("The public server cannot change Home membership")
        }
    }

    private func member(_ hostId: String, in ledger: HomeMembershipLedger) -> HomeMemberRecord? {
        guard let index = index(of: hostId, in: ledger.members) else { return nil }
        return ledger.members[index]
    }

    private func index(of hostId: String, in members: [HomeMemberRecord]) -> Int? {
        members.firstIndex { $0.hostId.caseInsensitiveCompare(hostId) == .orderedSame }
    }

    private func normalize(_ hostId: String) -> String {
        hostId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadOrEmptyLocked(now: Date) throws -> HomeMembershipLedger {
        if FileManager.default.fileExists(atPath: Self.ledgerURL(in: dataDir).path) {
            return try loadLocked()
        }
        return HomeMembershipLedger(
            revision: 0,
            lastSnapshotAt: now.timeIntervalSince1970,
            sharedSigningMaterialRetired: false,
            members: [],
        )
    }

    private func loadLocked() throws -> HomeMembershipLedger {
        let url = Self.ledgerURL(in: dataDir)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BarkVisorError.internalError("Membership ledger is unreadable")
        }
        do {
            return try JSONDecoder().decode(HomeMembershipLedger.self, from: data)
        } catch {
            throw BarkVisorError.internalError("Membership ledger is corrupt")
        }
    }

    private func persistLocked(_ ledger: HomeMembershipLedger) throws {
        let url = Self.ledgerURL(in: dataDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let data = try canonical(ledger)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path,
        )
    }

    private func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

private struct UnsignedSnapshot: Codable {
    var revision: Int
    var exportedAt: TimeInterval
    var signerHostId: String
    var signerCertificatePEM: String
    var members: [HomeMemberRecord]
}
