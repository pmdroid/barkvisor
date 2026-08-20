import Foundation
import GRDB

/// Snapshot returned by `GET .../guest-info`. Built from `guest_info` plus a NAT slirp fallback.
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
    public let listeningPorts: [GuestListeningPortDTO]?
    public let portsCollectedAt: String?

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
        listeningPorts: [GuestListeningPortDTO]? = nil,
        portsCollectedAt: String? = nil,
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
        self.listeningPorts = listeningPorts
        self.portsCollectedAt = portsCollectedAt
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
            listeningPorts: nil, portsCollectedAt: nil,
        )
    }
}

/// Guest-info helpers for health projection. Owned with QGA inventory (PAS-239).
public enum GuestHealthStore {
    public static func lastSeen(ids: [String], db: DatabasePool) async throws -> [String: String] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = try await db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }
        var seen: [String: String] = [:]
        for record in records where idSet.contains(record.vmId) {
            seen[record.vmId] = record.updatedAt
        }
        return seen
    }

    public static func ipsByVM(ids: [String], db: DatabasePool) async -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        let idSet = Set(ids)
        let records = await (try? db.read { db in
            try GuestInfoRecord.fetchAll(db)
        }) ?? []
        var out: [String: [String]] = [:]
        for record in records where idSet.contains(record.vmId) {
            out[record.vmId] = JSONColumnCoding.decodeArray(String.self, from: record.ipAddresses)
                ?? []
        }
        return out
    }
}

/// qemu-guest-agent inventory (PAS-239).
///
/// Owns QGA collection: interfaces, osinfo, hostname, users, fsinfo, listening ports.
/// `MetricsCollector` only polls balloon/blockstats. `QMPClient` stays the transport.
public actor GuestAgentInventory {
    public static let pollIntervalSeconds = 5
    private static let pollInterval = UInt64(pollIntervalSeconds) * 1_000_000_000

    private let dbPool: DatabasePool
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    public func start(vmID: String, qmpSocketPath: String) {
        guard tasks[vmID] == nil else { return }

        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)

            while !Task.isCancelled {
                if let self {
                    await poll(vmID: vmID, qmpSocketPath: qmpSocketPath)
                }
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
        tasks[vmID] = task
    }

    public func stop(vmID: String) {
        tasks[vmID]?.cancel()
        tasks.removeValue(forKey: vmID)
        GuestListeningPorts.clearAttempt(vmID: vmID)

        do {
            _ = try dbPool.write { db in
                try GuestInfoRecord.deleteOne(db, key: vmID)
            }
        } catch {
            Log.vm.error("Failed to remove guest info for VM \(vmID): \(error)", vm: vmID)
        }
    }

    private func poll(vmID: String, qmpSocketPath: String) async {
        guard tasks[vmID] != nil else { return }
        let dbPool = dbPool
        await Task.detached {
            Self.collect(qmpSocketPath: qmpSocketPath, vmID: vmID, dbPool: dbPool)
        }.value
    }

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
            return result(from: record)
        }

        return try await fallbackResult(vmID: vmID, db: db)
    }

    // MARK: - Snapshot mapping

    static func result(from record: GuestInfoRecord) -> GuestInfoResult {
        let ips = JSONColumnCoding.decodeArray(String.self, from: record.ipAddresses) ?? []
        let users = JSONColumnCoding.decodeArray(GuestUserDTO.self, from: record.users)
        let filesystems = JSONColumnCoding.decodeArray(
            GuestFilesystemDTO.self, from: record.filesystems,
        )
        let listeningPorts = JSONColumnCoding.decodeArray(
            GuestListeningPortDTO.self, from: record.listeningPorts,
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
            listeningPorts: listeningPorts,
            portsCollectedAt: record.portsCollectedAt,
        )
    }

    static func fallbackResult(network: Network?) -> GuestInfoResult {
        if (try? NetworkCapability.effectiveMode(of: network)) == .nat {
            return .unavailable(
                ipAddresses: [HealthProbeTarget.slirpGuestIPv4],
                ipSource: "nat-default",
            )
        }
        return .unavailable(macAddress: network?.macAddress, ipSource: "waiting")
    }

    private static func fallbackResult(
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

        return fallbackResult(network: network)
    }
}
