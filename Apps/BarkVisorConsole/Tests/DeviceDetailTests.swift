import Foundation
import Testing
@testable import BarkVisorConsole

struct DeviceDetailTests {
    private let decoder = JSONDecoder()

    @Test func `stats history decodes cpu and memory`() throws {
        let json = """
        [
          {
            "timestamp": "2026-08-23T12:00:00Z",
            "hostCpuPercent": 12.4,
            "hostMemoryUsedMB": 8192,
            "hostMemoryTotalMB": 32768
          },
          {
            "timestamp": "2026-08-23T12:00:05.250Z",
            "hostCpuPercent": 40,
            "hostMemoryUsedMB": 16384,
            "hostMemoryTotalMB": 32768
          }
        ]
        """.data(using: .utf8)!

        let samples = try decoder.decode([SystemStatsSample].self, from: json)
        #expect(samples.count == 2)
        #expect(samples[0].hostCpuPercent == 12.4)
        #expect(samples[0].hostMemoryUsedMB == 8_192)
        let points = DeviceStatsHistory.points(from: samples)
        #expect(points.count == 2)
        #expect(points[0].cpuPercent == 12.4)
        #expect(points[0].memoryUsedGB == 8)
        #expect(points[1].memoryUsedGB == 16)
        #expect(points[1].memoryTotalGB == 32)
    }

    @Test func `unreachable skips fetch and has no series`() {
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room", reachable: true)
        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: false)
        #expect(DeviceStatsHistory.shouldFetch(living))
        #expect(DeviceStatsHistory.shouldFetch(studio))
        #expect(!DeviceStatsHistory.shouldFetch(garage))
        #expect(DeviceStatsHistory.points(from: []).isEmpty)
        #expect(DeviceStatsHistory.unreachableCopy.contains("did not answer"))
        #expect(DeviceStatsHistory.unreachableCopy.contains(Copy.device.lowercased()))
        #expect(!DeviceStatsHistory.unreachableCopy.localizedCaseInsensitiveContains("node"))
        #expect(!DeviceStatsHistory.unreachableCopy.localizedCaseInsensitiveContains("cluster"))
    }

    @Test func `history path uses local api or home proxy`() throws {
        let client = try APIClient(baseURL: #require(URL(string: "http://127.0.0.1:7777")))
        let studio = snapshot(hostId: "self", role: "self", title: "Studio")
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        #expect(client.scoped("/system/stats/history", on: nil) == "/api/system/stats/history")
        #expect(client.scoped("/system/stats/history", on: studio) == "/api/system/stats/history")
        #expect(
            client.scoped("/system/stats/history", on: living)
                == "/api/home/devices/peer/v1/system/stats/history",
        )
        #expect(client.scoped("/system/gpu-devices", on: living) == "/api/home/devices/peer/v1/system/gpu-devices")
    }

    @Test func `resources line is cpu and memory never gpu`() {
        var studio = snapshot(hostId: "self", role: "self", title: "Studio")
        studio.platform = HomeDevicePlatformSummary(os: "macOS", arch: "arm64")
        studio.resources = HomeDeviceResourceSummary(
            cpuCount: 10,
            memoryTotalMB: 32_768,
            memoryUsedMB: 8_192,
            cpuLoadPercent: 12.4,
        )
        studio.workloadCount = 2
        #expect(studio.resourcesLine == "CPU 12% · 8.0 / 32 GB")
        #expect(studio.resourcesLine?.localizedCaseInsensitiveContains("gpu") == false)
        #expect(studio.workloadLine == "2 workloads")
        #expect(studio.platformLabel == "macOS · arm64")

        studio.resources = HomeDeviceResourceSummary(
            cpuCount: 1,
            memoryTotalMB: 0,
            memoryUsedMB: 0,
            cpuLoadPercent: 0,
        )
        #expect(studio.resourcesLine == "CPU 0% · 0.0 / 0 GB")

        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        #expect(garage.resourcesLine == nil)
        #expect(garage.platformLabel == "Unknown platform")
        #expect(garage.workloadLine == "Health unavailable")
    }

    @Test func `keeps the last sixty history points`() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let samples = (0 ..< 65).map { index in
            SystemStatsSample(
                timestamp: formatter.string(from: Date(timeIntervalSince1970: Double(index))),
                hostCpuPercent: Double(index),
                hostMemoryUsedMB: 1_024,
                hostMemoryTotalMB: 32_768,
            )
        }
        let points = DeviceStatsHistory.points(from: samples)
        #expect(points.count == DeviceStatsHistory.maxPoints)
        #expect(points.first?.cpuPercent == 5)
        #expect(points.last?.cpuPercent == 64)
    }

    private func snapshot(
        hostId: String,
        role: String,
        title: String? = nil,
        reachable: Bool = true,
    ) -> HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: title ?? hostId,
            fingerprint: nil,
            agentHost: nil,
            agentPort: 7_777,
            pairedAt: nil,
            reachability: reachable ? "ok" : "unreachable",
            reachabilityError: reachable ? nil : "Device is unreachable",
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }
}
