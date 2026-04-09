import Foundation
import GRDB

// MARK: - Result Types

public struct GuestInfoResult {
    public let available: Bool
    public let ipAddresses: [String]
    public let macAddress: String?
    public let ipSource: String // "guest-agent", "nat-default", "waiting"
    public let hostname: String?
    public let osName: String?
    public let osVersion: String?
    public let osId: String?
    public let kernelVersion: String?
    public let kernelRelease: String?
    public let machine: String?
    public let timezone: String?
    public let timezoneOffset: Int?
    public let users: [GuestUserDTO]?
    public let filesystems: [GuestFilesystemDTO]?

    public init(
        available: Bool,
        ipAddresses: [String],
        macAddress: String?,
        ipSource: String,
        hostname: String?,
        osName: String?,
        osVersion: String?,
        osId: String?,
        kernelVersion: String?,
        kernelRelease: String?,
        machine: String?,
        timezone: String?,
        timezoneOffset: Int?,
        users: [GuestUserDTO]?,
        filesystems: [GuestFilesystemDTO]?,
    ) {
        self.available = available
        self.ipAddresses = ipAddresses
        self.macAddress = macAddress
        self.ipSource = ipSource
        self.hostname = hostname
        self.osName = osName
        self.osVersion = osVersion
        self.osId = osId
        self.kernelVersion = kernelVersion
        self.kernelRelease = kernelRelease
        self.machine = machine
        self.timezone = timezone
        self.timezoneOffset = timezoneOffset
        self.users = users
        self.filesystems = filesystems
    }

    static func unavailable(
        ipAddresses: [String] = [],
        macAddress: String? = nil,
        ipSource: String,
    ) -> GuestInfoResult {
        GuestInfoResult(
            available: false, ipAddresses: ipAddresses, macAddress: macAddress,
            ipSource: ipSource, hostname: nil, osName: nil, osVersion: nil,
            osId: nil, kernelVersion: nil, kernelRelease: nil, machine: nil,
            timezone: nil, timezoneOffset: nil, users: nil, filesystems: nil,
        )
    }
}

// MARK: - Guest Info & Failure Handlers

extension VMLifecycleService {
    public static func getGuestInfo(
        vmID: String,
        vmManager: VMManager,
        db: DatabasePool,
    ) async throws -> GuestInfoResult {
        guard await vmManager.isRunning(vmID) else {
            throw BarkVisorError.conflict("VM is not running")
        }

        let record = try await db.read { db in
            try GuestInfoRecord.fetchOne(db, key: vmID)
        }

        if let record {
            return buildGuestInfoFromRecord(record)
        }

        return try await buildGuestInfoFallback(vmID: vmID, db: db)
    }

    private static func buildGuestInfoFromRecord(_ record: GuestInfoRecord) -> GuestInfoResult {
        let ips = JSONColumnCoding.decodeArray(String.self, from: record.ipAddresses) ?? []
        let users = JSONColumnCoding.decodeArray(GuestUserDTO.self, from: record.users)
        let filesystems = JSONColumnCoding.decodeArray(
            GuestFilesystemDTO.self, from: record.filesystems,
        )

        return GuestInfoResult(
            available: true,
            ipAddresses: ips,
            macAddress: record.macAddress,
            ipSource: ips.isEmpty ? "waiting" : "guest-agent",
            hostname: record.hostname,
            osName: record.osName,
            osVersion: record.osVersion,
            osId: record.osId,
            kernelVersion: record.kernelVersion,
            kernelRelease: record.kernelRelease,
            machine: record.machine,
            timezone: record.timezone,
            timezoneOffset: record.timezoneOffset,
            users: users,
            filesystems: filesystems,
        )
    }

    private static func buildGuestInfoFallback(
        vmID: String,
        db: DatabasePool,
    ) async throws -> GuestInfoResult {
        let vm = try await db.read { db in try VM.fetchOne(db, key: vmID) }
        guard let vm else { throw BarkVisorError.notFound() }

        let network: Network? =
            if let netId = vm.networkId {
                try await db.read { db in try Network.fetchOne(db, key: netId) }
            } else {
                nil
            }

        if network == nil || network?.mode == "nat" {
            return .unavailable(ipAddresses: ["10.0.2.15"], ipSource: "nat-default")
        }

        return .unavailable(macAddress: network?.macAddress, ipSource: "waiting")
    }

    static func handleProvisionFailure(
        vmID: String,
        diskID: String,
        diskPath: String,
        db: DatabasePool,
        error: Error,
    ) async {
        try? FileManager.default.removeItem(atPath: diskPath)
        try? FileManager.default.removeItem(
            at: Config.dataDir.appendingPathComponent("cloud-init/\(vmID)"),
        )

        let now = iso8601.string(from: Date())
        do {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE vms SET state = 'error', cloudInitPath = NULL, updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
                try db.execute(
                    sql: "UPDATE disks SET status = 'creating' WHERE id = ?",
                    arguments: [diskID],
                )
            }
            Log.vm.error("Provisioning failed for VM \(vmID): \(error)", vm: vmID)
        } catch {
            Log.vm.error("Failed to mark provisioning failure for VM \(vmID): \(error)", vm: vmID)
        }
    }

    static func handleDeleteFailure(
        vmID: String,
        db: DatabasePool,
        error: Error,
    ) async {
        let now = iso8601.string(from: Date())
        do {
            try await db.write { db in
                try db.execute(
                    sql: "UPDATE vms SET state = 'error', updatedAt = ? WHERE id = ?",
                    arguments: [now, vmID],
                )
            }
            Log.vm.error("VM deletion failed for \(vmID): \(error)", vm: vmID)
        } catch {
            Log.vm.error("Failed to mark delete failure for VM \(vmID): \(error)", vm: vmID)
        }
    }
}
