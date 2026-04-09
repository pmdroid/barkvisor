import Foundation
import GRDB

extension MetricsCollector {
    static func pollQMP(
        qmpSocketPath: String,
        vmID: String,
        dbPool: DatabasePool,
        prevDiskReadVal: Int64?,
        prevDiskWriteVal: Int64?,
    ) -> QMPPollResult {
        var memoryUsedMB = 0
        var diskRead: Int64 = 0
        var diskWrite: Int64 = 0
        var newTotalRead: Int64?
        var newTotalWrite: Int64?

        let client = QMPClient(socketPath: qmpSocketPath)
        if (try? client.connect()) != nil {
            defer { client.disconnect() }

            memoryUsedMB = queryBalloonMemory(client: client)

            let diskResult = queryDiskStats(
                client: client,
                prevDiskReadVal: prevDiskReadVal,
                prevDiskWriteVal: prevDiskWriteVal,
            )
            if let result = diskResult {
                diskRead = result.diskRead
                diskWrite = result.diskWrite
                newTotalRead = result.newTotalRead
                newTotalWrite = result.newTotalWrite
            }
        }

        pollGuestAgent(qmpSocketPath: qmpSocketPath, vmID: vmID, dbPool: dbPool)

        return QMPPollResult(
            memoryUsedMB: memoryUsedMB,
            diskRead: diskRead,
            diskWrite: diskWrite,
            newTotalRead: newTotalRead,
            newTotalWrite: newTotalWrite,
        )
    }

    private static func queryBalloonMemory(client: QMPClient) -> Int {
        guard let balloonResult = try? client.execute("query-balloon"),
              let returnVal = balloonResult["return"] as? [String: Any]
        else { return 0 }

        if let actual = returnVal["actual"] as? Int64 {
            return Int(actual / (1_024 * 1_024))
        } else if let actual = returnVal["actual"] as? Int {
            return actual / (1_024 * 1_024)
        }
        return 0
    }

    private static func queryDiskStats(
        client: QMPClient,
        prevDiskReadVal: Int64?,
        prevDiskWriteVal: Int64?,
    ) -> (diskRead: Int64, diskWrite: Int64, newTotalRead: Int64, newTotalWrite: Int64)? {
        guard let blockResult = try? client.execute("query-blockstats"),
              let returnVal = blockResult["return"] as? [[String: Any]]
        else { return nil }

        var totalRead: Int64 = 0
        var totalWrite: Int64 = 0
        for device in returnVal {
            if let stats = device["stats"] as? [String: Any] {
                if let r = stats["rd_bytes"] as? Int64 {
                    totalRead += r
                } else if let r = stats["rd_bytes"] as? Int {
                    totalRead += Int64(r)
                }
                if let w = stats["wr_bytes"] as? Int64 {
                    totalWrite += w
                } else if let w = stats["wr_bytes"] as? Int {
                    totalWrite += Int64(w)
                }
            }
        }

        let prevR = prevDiskReadVal ?? totalRead
        let prevW = prevDiskWriteVal ?? totalWrite
        return (
            diskRead: totalRead - prevR,
            diskWrite: totalWrite - prevW,
            newTotalRead: totalRead,
            newTotalWrite: totalWrite,
        )
    }

    private static func pollGuestAgent(qmpSocketPath: String, vmID: String, dbPool: DatabasePool) {
        let gaSockPath = qmpSocketPath.replacingOccurrences(of: "-qmp.sock", with: "-ga.sock")
        let gaClient = QMPClient(socketPath: gaSockPath)
        guard (try? gaClient.connectRaw(timeoutSeconds: 1)) != nil else { return }
        defer { gaClient.disconnect() }

        let syncId = Int.random(in: 1 ... 999_999)
        _ = try? gaClient.executeWithArgs("guest-sync", args: ["id": syncId])

        guard let gaResult = try? gaClient.execute("guest-network-get-interfaces") else { return }

        let (ips, mac) = parseNetworkInterfaces(gaResult)
        let record = buildGuestInfoRecord(gaClient: gaClient, vmID: vmID, ips: ips, mac: mac)

        do {
            try dbPool.write { db in
                try record.save(db, onConflict: .replace)
            }
        } catch {
            Log.metrics.error("Failed to save guest info for VM \(vmID): \(error)", vm: vmID)
        }
    }

    private static func parseNetworkInterfaces(
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

    private static func buildGuestInfoRecord(
        gaClient: QMPClient, vmID: String, ips: [String], mac: String?,
    ) -> GuestInfoRecord {
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

        let encoder = JSONEncoder()
        return GuestInfoRecord(
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
            updatedAt: iso8601.string(from: Date()),
        )
    }

    private static func parseGuestUsers(
        _ usersResult: [String: Any]?,
    ) -> [GuestUserDTO]? {
        guard let userList = usersResult?["return"] as? [[String: Any]] else { return nil }
        return userList.compactMap { u in
            guard let name = u["user"] as? String else { return nil }
            let loginTime = u["login-time"] as? Double
            return GuestUserDTO(name: name, loginTime: loginTime)
        }
    }

    private static func parseGuestFilesystems(
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
}
