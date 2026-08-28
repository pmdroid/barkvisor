import Foundation
import Testing
@testable import BarkVisorCore

struct ImageDownloadSpaceTests {
    @Test func `unknown sizeBytes skips the check`() throws {
        try ImageDownloadSpace.require(sizeBytes: nil, freeBytes: 1, deviceName: "studio")
        try ImageDownloadSpace.require(sizeBytes: 0, freeBytes: 1, deviceName: "studio")
        try ImageDownloadSpace.require(sizeBytes: 1_000, freeBytes: nil, deviceName: "studio")
    }

    @Test func `sizeBytes plus headroom that fits does not throw`() throws {
        let free = UInt64(ImageDownloadSpace.headroomBytes) + 2
        try ImageDownloadSpace.require(sizeBytes: 1, freeBytes: free, deviceName: "studio")
    }

    @Test func `sizeBytes over freeBytes names the Device and shortfall`() throws {
        do {
            try ImageDownloadSpace.require(
                sizeBytes: 100_000_000,
                freeBytes: 1,
                deviceName: "studio",
            )
            Issue.record("expected shortfall")
        } catch let BarkVisorError.insufficientDeviceDiskSpace(deviceName, shortfallBytes) {
            #expect(deviceName == "studio")
            #expect(shortfallBytes == Int64(100_000_000) + ImageDownloadSpace.headroomBytes - 1)
            #expect(
                BarkVisorError.insufficientDeviceDiskSpace(
                    deviceName: deviceName, shortfallBytes: shortfallBytes,
                ).errorDescription?
                    .contains("Not enough disk space on this Device studio") == true,
            )
        }
    }

    @Test func `headroom fails when free equals sizeBytes plus 64 MiB minus one`() throws {
        let size: Int64 = 1
        let free = UInt64(size + ImageDownloadSpace.headroomBytes - 1)
        do {
            try ImageDownloadSpace.require(
                sizeBytes: size, freeBytes: free, deviceName: "studio",
            )
            Issue.record("expected headroom shortfall")
        } catch let BarkVisorError.insufficientDeviceDiskSpace(_, shortfallBytes) {
            #expect(shortfallBytes == 1)
        }
    }
}
