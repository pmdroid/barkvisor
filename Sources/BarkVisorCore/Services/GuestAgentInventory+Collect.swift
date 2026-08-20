import Foundation
import GRDB

extension GuestAgentInventory {
    static func collect(qmpSocketPath: String, vmID: String, dbPool: DatabasePool) {
        let gaSockPath = VMSockets(qmpSocketPath: qmpSocketPath)?.guestAgent.path
            ?? VMSockets(vmID: vmID).guestAgent.path
        let gaClient = QMPClient(socketPath: gaSockPath)
        guard (try? gaClient.connectRaw(timeoutSeconds: 1)) != nil else { return }
        defer { gaClient.disconnect() }

        _ = try? GuestAgentChannel.handshake(gaClient)

        guard let gaResult = try? gaClient.execute("guest-network-get-interfaces") else { return }

        let (ips, mac) = parseNetworkInterfaces(gaResult)
        let previousAndType = try? dbPool.read { db -> (GuestInfoRecord?, String?) in
            let previous = try GuestInfoRecord.fetchOne(db, key: vmID)
            let vmType = try VM.fetchOne(db, key: vmID)?.vmType
            return (previous, vmType)
        }
        let snapshot = buildGuestInfoRecord(
            gaClient: gaClient,
            vmID: vmID,
            ips: ips,
            mac: mac,
            previous: previousAndType?.0,
            vmType: previousAndType?.1,
        )

        do {
            try dbPool.write { db in
                try snapshot.record.saveRefreshing(db, updatePorts: snapshot.updatePorts)
            }
        } catch {
            Log.vm.error("Failed to save guest info for VM \(vmID): \(error)", vm: vmID)
        }
    }

    static func parseNetworkInterfaces(
        _ gaResult: [String: Any],
    ) -> (ips: [String], mac: String?) {
        var ips: [String] = []
        var mac: String?
        guard let ifaces = gaResult["return"] as? [[String: Any]] else { return (ips, mac) }

        for iface in ifaces {
            let name = iface["name"] as? String ?? ""
            if name == "lo" { continue }
            if mac == nil { mac = iface["hardware-address"] as? String }
            if let addrs = iface["ip-addresses"] as? [[String: Any]] {
                for addr in addrs {
                    if let type = addr["ip-address-type"] as? String, type == "ipv4",
                       let ip = addr["ip-address"] as? String {
                        ips.append(ip)
                    }
                }
            }
        }
        return (ips, mac)
    }

    static func parseGuestUsers(
        _ usersResult: [String: Any]?,
    ) -> [GuestUserDTO]? {
        guard let userList = usersResult?["return"] as? [[String: Any]] else { return nil }
        return userList.compactMap { u in
            guard let name = u["user"] as? String else { return nil }
            let loginTime = u["login-time"] as? Double
            return GuestUserDTO(name: name, loginTime: loginTime)
        }
    }

    static func parseGuestFilesystems(
        _ fsResult: [String: Any]?,
    ) -> [GuestFilesystemDTO]? {
        guard let fsList = fsResult?["return"] as? [[String: Any]] else { return nil }
        return fsList.compactMap { fs in
            guard let mountpoint = fs["mountpoint"] as? String else { return nil }
            let fsType = fs["type"] as? String ?? "unknown"
            let device = fs["name"] as? String ?? "unknown"
            let totalBytes: Int64? =
                if let v = fs["total-bytes"] as? Int64 {
                    v
                } else if let v = fs["total-bytes"] as? Int {
                    Int64(v)
                } else {
                    nil
                }
            let usedBytes: Int64? =
                if let v = fs["used-bytes"] as? Int64 {
                    v
                } else if let v = fs["used-bytes"] as? Int {
                    Int64(v)
                } else {
                    nil
                }
            return GuestFilesystemDTO(
                mountpoint: mountpoint, type: fsType, device: device,
                totalBytes: totalBytes, usedBytes: usedBytes,
            )
        }
    }

    // Same collect mapping as MetricsCollector+QMP before PAS-239.
    // swiftlint:disable:next function_parameter_count
    private static func buildGuestInfoRecord(
        gaClient: QMPClient,
        vmID: String,
        ips: [String],
        mac: String?,
        previous: GuestInfoRecord?,
        vmType: String?,
    ) -> (record: GuestInfoRecord, updatePorts: Bool) {
        let hostnameResult = try? gaClient.execute("guest-get-host-name")
        let osInfoResult = try? gaClient.execute("guest-get-osinfo")
        let tzResult = try? gaClient.execute("guest-get-timezone")
        let usersResult = try? gaClient.execute("guest-get-users")
        let fsResult = try? gaClient.execute("guest-get-fsinfo")

        let hostName = (hostnameResult?["return"] as? [String: Any])?["host-name"] as? String
        let os = osInfoResult?["return"] as? [String: Any]
        let osName = os?["name"] as? String ?? os?["pretty-name"] as? String
        let osVersion = os?["version"] as? String ?? os?["version-id"] as? String
        let osId = os?["id"] as? String
        let kernelVersion = os?["kernel-version"] as? String
        let kernelRelease = os?["kernel-release"] as? String
        let machine = os?["machine"] as? String

        let tz = tzResult?["return"] as? [String: Any]
        let tzName = tz?["zone"] as? String
        let tzOffset = tz?["offset"] as? Int

        let parsedUsers = parseGuestUsers(usersResult)
        let parsedFS = parseGuestFilesystems(fsResult)
        let now = iso8601.string(from: Date())
        let persistedPorts: (json: String?, collectedAt: String?, changed: Bool)
        if GuestListeningPorts.shouldCollect(vmID: vmID) {
            let osHint = [vmType, osId, osName, osVersion, kernelVersion, kernelRelease]
                .compactMap(\.self)
                .joined(separator: " ")
            let collectedPorts = GuestListeningPorts.collect(using: gaClient, osHint: osHint)
            GuestListeningPorts.markCollected(vmID: vmID, succeeded: collectedPorts != nil)
            persistedPorts = GuestListeningPorts.persistFields(
                collected: collectedPorts,
                previousJSON: previous?.listeningPorts,
                previousCollectedAt: previous?.portsCollectedAt,
                now: now,
            )
        } else {
            persistedPorts = (previous?.listeningPorts, previous?.portsCollectedAt, false)
        }

        let encoder = JSONEncoder()
        let record = GuestInfoRecord(
            vmId: vmID,
            hostname: hostName,
            osName: osName,
            osVersion: osVersion,
            osId: osId,
            kernelVersion: kernelVersion,
            kernelRelease: kernelRelease,
            machine: machine,
            timezone: tzName,
            timezoneOffset: tzOffset,
            ipAddresses: String(
                data: (try? encoder.encode(ips)) ?? Data("[]".utf8), encoding: .utf8,
            ),
            macAddress: mac,
            users: String(
                data: (try? encoder.encode(parsedUsers)) ?? Data("[]".utf8), encoding: .utf8,
            ),
            filesystems: String(
                data: (try? encoder.encode(parsedFS)) ?? Data("[]".utf8), encoding: .utf8,
            ),
            updatedAt: now,
            listeningPorts: persistedPorts.json,
            portsCollectedAt: persistedPorts.collectedAt,
        )
        return (record, persistedPorts.changed)
    }
}
