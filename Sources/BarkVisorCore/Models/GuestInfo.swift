import GRDB

public struct GuestInfoRecord: Codable, Sendable, FetchableRecord, PersistableRecord, TableRecord {
    public static let databaseTableName = "guest_info"

    public var vmId: String
    public var hostname: String?
    public var osName: String?
    public var osVersion: String?
    public var osId: String?
    public var kernelVersion: String?
    public var kernelRelease: String?
    public var machine: String?
    public var timezone: String?
    public var timezoneOffset: Int?
    public var ipAddresses: String? // JSON-encoded [String]
    public var macAddress: String?
    public var users: String? // JSON-encoded [GuestUserDTO]
    public var filesystems: String? // JSON-encoded [GuestFilesystemDTO]
    public var updatedAt: String

    public init(
        vmId: String,
        hostname: String?,
        osName: String?,
        osVersion: String?,
        osId: String?,
        kernelVersion: String?,
        kernelRelease: String?,
        machine: String?,
        timezone: String?,
        timezoneOffset: Int?,
        ipAddresses: String?,
        macAddress: String?,
        users: String?,
        filesystems: String?,
        updatedAt: String,
    ) {
        self.vmId = vmId
        self.hostname = hostname
        self.osName = osName
        self.osVersion = osVersion
        self.osId = osId
        self.kernelVersion = kernelVersion
        self.kernelRelease = kernelRelease
        self.machine = machine
        self.timezone = timezone
        self.timezoneOffset = timezoneOffset
        self.ipAddresses = ipAddresses
        self.macAddress = macAddress
        self.users = users
        self.filesystems = filesystems
        self.updatedAt = updatedAt
    }
}

public struct GuestUserDTO: Codable, Sendable {
    public let name: String
    public let loginTime: Double?

    public init(name: String, loginTime: Double?) {
        self.name = name
        self.loginTime = loginTime
    }
}

public struct GuestFilesystemDTO: Codable, Sendable {
    public let mountpoint: String
    public let type: String
    public let device: String
    public let totalBytes: Int64?
    public let usedBytes: Int64?

    public init(
        mountpoint: String,
        type: String,
        device: String,
        totalBytes: Int64?,
        usedBytes: Int64?,
    ) {
        self.mountpoint = mountpoint
        self.type = type
        self.device = device
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
    }
}
