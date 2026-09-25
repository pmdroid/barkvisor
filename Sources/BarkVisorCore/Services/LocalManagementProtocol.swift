import Foundation

public enum ServiceProcessRole: String, Sendable, Equatable, Codable {
    case barkServer = "bark-server"
    case barkDaemon = "bark-daemon"
    case combined
}

public enum ServiceProcessRoleError: Error, Equatable, Sendable {
    case serverCannotOpenAuthoritativeState
    case serverRefusesRoot
    case handshakeRejected
    case unavailable
}

public enum BarkServerStartup {
    public static func refuseRoot(euid: UInt32) throws {
        if euid == 0 {
            throw ServiceProcessRoleError.serverRefusesRoot
        }
    }

    public static func requireHandshake(_ response: LocalManagementResponse) throws {
        if !response.accepted {
            throw ServiceProcessRoleError.handshakeRejected
        }
    }
}

public enum VaporListenerGate {
    public static func authoritativeStartAllowed(role: ServiceProcessRole) -> Bool {
        role == .combined
    }
}

public struct ListenerPlan: Equatable, Sendable {
    public var publicHTTP: Bool
    public var deviceTLS: Bool
    public var managementListen: Bool
    public var tcpManagement: Bool

    public init(
        publicHTTP: Bool,
        deviceTLS: Bool,
        managementListen: Bool,
        tcpManagement: Bool,
    ) {
        self.publicHTTP = publicHTTP
        self.deviceTLS = deviceTLS
        self.managementListen = managementListen
        self.tcpManagement = tcpManagement
    }

    public static func forRole(_ role: ServiceProcessRole) -> ListenerPlan {
        switch role {
        case .barkDaemon:
            ListenerPlan(
                publicHTTP: false,
                deviceTLS: false,
                managementListen: true,
                tcpManagement: false,
            )
        case .barkServer:
            ListenerPlan(
                publicHTTP: true,
                deviceTLS: true,
                managementListen: false,
                tcpManagement: false,
            )
        case .combined:
            ListenerPlan(
                publicHTTP: true,
                deviceTLS: true,
                managementListen: false,
                tcpManagement: false,
            )
        }
    }
}

public struct PrivilegeBoundary: Equatable, Sendable {
    public var canMutateHostNetwork: Bool
    public var canInstallPackages: Bool
    public var canOpenDockerSocket: Bool
    public var canOpenRawDisk: Bool
    public var canWriteAuthoritativeState: Bool
    public var canWriteRootExecutedFiles: Bool

    public init(
        canMutateHostNetwork: Bool,
        canInstallPackages: Bool,
        canOpenDockerSocket: Bool,
        canOpenRawDisk: Bool,
        canWriteAuthoritativeState: Bool,
        canWriteRootExecutedFiles: Bool,
    ) {
        self.canMutateHostNetwork = canMutateHostNetwork
        self.canInstallPackages = canInstallPackages
        self.canOpenDockerSocket = canOpenDockerSocket
        self.canOpenRawDisk = canOpenRawDisk
        self.canWriteAuthoritativeState = canWriteAuthoritativeState
        self.canWriteRootExecutedFiles = canWriteRootExecutedFiles
    }

    public static func forRole(_ role: ServiceProcessRole) -> PrivilegeBoundary {
        switch role {
        case .barkServer:
            PrivilegeBoundary(
                canMutateHostNetwork: false,
                canInstallPackages: false,
                canOpenDockerSocket: false,
                canOpenRawDisk: false,
                canWriteAuthoritativeState: false,
                canWriteRootExecutedFiles: false,
            )
        case .barkDaemon, .combined:
            PrivilegeBoundary(
                canMutateHostNetwork: true,
                canInstallPackages: true,
                canOpenDockerSocket: true,
                canOpenRawDisk: true,
                canWriteAuthoritativeState: true,
                canWriteRootExecutedFiles: true,
            )
        }
    }

    public var serverIsUnprivileged: Bool {
        !canMutateHostNetwork && !canInstallPackages && !canOpenDockerSocket && !canOpenRawDisk
            && !canWriteAuthoritativeState && !canWriteRootExecutedFiles
    }
}

public enum LocalManagementLimits {
    public static let version = 1
    public static let schemaVersion = 1
    public static let maxPayloadBytes = 1_048_576
    public static let maxEventBytes = 262_144
    public static let maxIdentifierLength = 128
    public static let maxTokenLength = 512
    public static let maxMarkerLength = 1_024
}

public enum LocalManagementCompatibility {
    public static func accepts(version: Int) -> Bool {
        version == LocalManagementLimits.version
    }
}

public enum LocalManagementError: Error, Equatable, Sendable {
    case connectionLost
    case payloadTooLarge
    case malformed
    case unavailable
}

public struct LocalPeerIdentity: Equatable, Sendable {
    public var uid: UInt32
    public var gid: UInt32
    public var pid: Int32

    public init(uid: UInt32, gid: UInt32, pid: Int32) {
        self.uid = uid
        self.gid = gid
        self.pid = pid
    }
}

public struct MembershipFact: Equatable, Sendable {
    public var subject: String
    public var sessionToken: String
    public var revoked: Bool

    public init(subject: String, sessionToken: String, revoked: Bool) {
        self.subject = subject
        self.sessionToken = sessionToken
        self.revoked = revoked
    }
}

public struct ResourcePolicy: Equatable, Sendable {
    public var allowedRoots: [String]
    public var allowedMounts: Set<String>
    public var allowedDevices: Set<String>

    public init(allowedRoots: [String], allowedMounts: Set<String>, allowedDevices: Set<String>) {
        self.allowedRoots = allowedRoots
        self.allowedMounts = allowedMounts
        self.allowedDevices = allowedDevices
    }
}

public struct LocalManagementPolicy: Equatable, Sendable {
    public var allowedPeerUIDs: Set<UInt32>
    public var memberships: [MembershipFact]
    public var resources: ResourcePolicy
    public var maxEventBytes: Int

    public init(
        allowedPeerUIDs: Set<UInt32>,
        memberships: [MembershipFact],
        resources: ResourcePolicy,
        maxEventBytes: Int = LocalManagementLimits.maxEventBytes,
    ) {
        self.allowedPeerUIDs = allowedPeerUIDs
        self.memberships = memberships
        self.resources = resources
        self.maxEventBytes = maxEventBytes
    }
}

public struct SocketPermissionPlan: Equatable, Sendable {
    public var directoryMode: UInt16
    public var socketMode: UInt16

    public init(directoryMode: UInt16, socketMode: UInt16) {
        self.directoryMode = directoryMode
        self.socketMode = socketMode
    }

    public static func forDaemonEUID(_ euid: UInt32) -> SocketPermissionPlan {
        if euid == 0 {
            SocketPermissionPlan(directoryMode: 0o750, socketMode: 0o660)
        } else {
            SocketPermissionPlan(directoryMode: 0o700, socketMode: 0o600)
        }
    }
}

public enum ManagementSocketPath {
    public static func path(socketDir: URL) -> String {
        socketDir
            .appendingPathComponent("management", isDirectory: true)
            .appendingPathComponent("barkvisor.sock")
            .path
    }
}

public enum LocalManagementPeers {
    public static func allowlist(daemonEUID: UInt32, serverUID: UInt32?) -> Set<UInt32> {
        if daemonEUID == 0 {
            guard let serverUID, serverUID != 0 else { return [] }
            return [serverUID]
        }
        return [daemonEUID]
    }
}

public struct LocalManagementRequest: Codable, Equatable, Sendable {
    public var version: Int
    public var requestId: String
    public var operationId: String
    public var name: String
    public var claimedUserId: String?
    public var sessionToken: String?
    public var paths: [String]
    public var mounts: [String]
    public var devices: [String]
    public var terminalUID: UInt32?
    public var marker: String?
    public var workloadID: String?
    public var schemaVersion: Int?

    public init(
        version: Int = LocalManagementLimits.version,
        requestId: String,
        operationId: String,
        name: String,
        claimedUserId: String? = nil,
        sessionToken: String? = nil,
        paths: [String] = [],
        mounts: [String] = [],
        devices: [String] = [],
        terminalUID: UInt32? = nil,
        marker: String? = nil,
        workloadID: String? = nil,
        schemaVersion: Int? = nil,
    ) {
        self.version = version
        self.requestId = requestId
        self.operationId = operationId
        self.name = name
        self.claimedUserId = claimedUserId
        self.sessionToken = sessionToken
        self.paths = paths
        self.mounts = mounts
        self.devices = devices
        self.terminalUID = terminalUID
        self.marker = marker
        self.workloadID = workloadID
        self.schemaVersion = schemaVersion
    }
}

public struct LocalManagementResponse: Codable, Equatable, Sendable {
    public var version: Int
    public var requestId: String
    public var operationId: String
    public var accepted: Bool
    public var phase: String
    public var effectCount: Int
    public var rejection: String?
    public var subject: String?
    public var marker: String?
    public var workloadID: String?
    public var workloadState: String?
    public var events: [String]?

    public init(
        version: Int = LocalManagementLimits.version,
        requestId: String,
        operationId: String,
        accepted: Bool,
        phase: String,
        effectCount: Int,
        rejection: String? = nil,
        subject: String? = nil,
        marker: String? = nil,
        workloadID: String? = nil,
        workloadState: String? = nil,
        events: [String]? = nil,
    ) {
        self.version = version
        self.requestId = requestId
        self.operationId = operationId
        self.accepted = accepted
        self.phase = phase
        self.effectCount = effectCount
        self.rejection = rejection
        self.subject = subject
        self.marker = marker
        self.workloadID = workloadID
        self.workloadState = workloadState
        self.events = events
    }

    public static func rejection(
        request: LocalManagementRequest,
        reason: LocalRejection,
    ) -> LocalManagementResponse {
        LocalManagementResponse(
            requestId: request.requestId,
            operationId: request.operationId,
            accepted: false,
            phase: "rejected",
            effectCount: 0,
            rejection: reason.rawValue,
        )
    }
}

public enum LocalRejection: String, Codable, Sendable, Equatable {
    case peerNotAllowed
    case missingCredential
    case forgedIdentity
    case revokedMember
    case unknownSession
    case invalidPath
    case unauthorizedMount
    case unauthorizedDevice
    case unsupportedProtocol
    case malformed
    case payloadTooLarge
    case unknownOperation
    case terminalRootRejected
    case operationNotVisible
    case slowConsumer
}

public struct AuthorizationDecision: Equatable, Sendable {
    public var requestId: String
    public var operationId: String
    public var allowed: Bool
    public var reason: String
    public var subject: String?

    public init(
        requestId: String,
        operationId: String,
        allowed: Bool,
        reason: String,
        subject: String? = nil,
    ) {
        self.requestId = requestId
        self.operationId = operationId
        self.allowed = allowed
        self.reason = reason
        self.subject = subject
    }
}
