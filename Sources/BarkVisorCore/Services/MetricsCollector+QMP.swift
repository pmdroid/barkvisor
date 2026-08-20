import Foundation

extension MetricsCollector {
    static func pollQMP(
        qmpSocketPath: String,
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
}
