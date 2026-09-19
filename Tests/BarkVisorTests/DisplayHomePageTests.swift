import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Display home page")
struct DisplayHomePageTests {
    @Test func `quad includes reachable stats and inverts unreachable`() throws {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "MacMini"),
            HomeDevice(hostId: "down", role: "member", displayName: "agentbox"),
            HomeDevice(hostId: "gpu", role: "member", displayName: "goldbox"),
        ])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: HomeDeviceLiveFacts(
                displayName: "MacMini",
                platform: HomeDevicePlatformSummary(os: "macOS", arch: "arm64"),
                resources: HomeDeviceResourceSummary(
                    cpuCount: 10,
                    memoryTotalMB: 24_576,
                    memoryUsedMB: 18_432,
                    cpuLoadPercent: 18,
                ),
                workloadCount: 4,
                healthCounts: ["running": 4],
            ),
            members: [
                "down": .unreachable("Device is unreachable"),
                "gpu": .ok(
                    HomeDeviceLiveFacts(
                        displayName: "goldbox",
                        platform: HomeDevicePlatformSummary(os: "Linux", arch: "arm64"),
                        resources: HomeDeviceResourceSummary(
                            cpuCount: 20,
                            memoryTotalMB: 131_072,
                            memoryUsedMB: 49_152,
                            cpuLoadPercent: 41,
                            gpuPercent: 72,
                            cpuTemperatureC: 52,
                            gpuTemperatureC: 67,
                        ),
                        workloadCount: 2,
                        healthCounts: ["running": 1, "failed": 1],
                    ),
                ),
            ],
        )
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let html = DisplayHomePage.html(
            report: report,
            now: Date(timeIntervalSince1970: 1_700_000_000),
            timeZone: zone,
        )
        #expect(html.contains("MacMini"))
        #expect(html.contains("agentbox"))
        #expect(html.contains("goldbox"))
        #expect(html.contains("Unreachable"))
        #expect(html.contains("2/3 up"))
        #expect(html.contains("GPU"))
        #expect(html.contains("72%"))
        #expect(html.contains("CPU 52°C"))
        #expect(html.contains("GPU 67°C"))
        #expect(html.contains("2 workloads"))
        #expect(html.contains("1 failed"))
        #expect(html.contains("card down"))
        let from = try #require(html.range(of: "MacMini"))
        let to = try #require(html.range(of: "agentbox"))
        let miniSlice = html[from.lowerBound ..< to.lowerBound]
        #expect(!miniSlice.contains("GPU"))
    }

    @Test func `four up and one down still wraps five tiles`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "MacMini"),
            HomeDevice(hostId: "down", role: "member", displayName: "agentbox"),
            HomeDevice(hostId: "a", role: "member", displayName: "goldbox"),
            HomeDevice(hostId: "b", role: "member", displayName: "steamdeck"),
            HomeDevice(hostId: "c", role: "member", displayName: "studio"),
        ])
        let ok = HomeDeviceLiveFacts(
            displayName: "peer",
            platform: HomeDevicePlatformSummary(os: "Linux", arch: "arm64"),
            resources: HomeDeviceResourceSummary(cpuLoadPercent: 10),
        )
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: HomeDeviceLiveFacts(
                displayName: "MacMini",
                platform: HomeDevicePlatformSummary(os: "macOS", arch: "arm64"),
                resources: HomeDeviceResourceSummary(cpuLoadPercent: 8),
            ),
            members: [
                "down": .unreachable("Device is unreachable"),
                "a": .ok(ok),
                "b": .ok(ok),
                "c": .ok(ok),
            ],
        )
        let html = DisplayHomePage.html(report: report)
        #expect(html.contains("quad n5 tight"))
        #expect(html.contains("board tight"))
        #expect(html.contains("agentbox"))
        #expect(html.contains("Unreachable"))
        #expect(html.contains("4/5 up"))
    }

    @Test func `five reachable devices wrap two columns`() {
        let names = ["MacMini", "goldbox", "steamdeck", "studio", "nas"]
        let listed = HomeDeviceList(devices: names.enumerated().map { index, name in
            HomeDevice(
                hostId: name,
                role: index == 0 ? "self" : "member",
                displayName: name,
            )
        })
        var members: [String: HomeDeviceProbeOutcome] = [:]
        for name in names.dropFirst() {
            members[name] = .ok(
                HomeDeviceLiveFacts(
                    displayName: name,
                    platform: HomeDevicePlatformSummary(os: "Linux", arch: "arm64"),
                    resources: HomeDeviceResourceSummary(cpuLoadPercent: 10),
                ),
            )
        }
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: HomeDeviceLiveFacts(
                displayName: "MacMini",
                platform: HomeDevicePlatformSummary(os: "macOS", arch: "arm64"),
                resources: HomeDeviceResourceSummary(cpuLoadPercent: 8),
            ),
            members: members,
        )
        let html = DisplayHomePage.html(report: report)
        #expect(html.contains("quad n5 tight"))
        for name in names {
            #expect(html.contains(name))
        }
    }

    @Test func `old resource json without gpu stays nil not zero`() throws {
        let data = Data(#"{"cpuCount":2,"memoryTotalMB":4096,"memoryUsedMB":1024,"cpuLoadPercent":8}"#.utf8)
        let decoded = try JSONDecoder().decode(ResourcesInfo.self, from: data)
        #expect(decoded.gpuPercent == nil)
        #expect(decoded.temperatureC == nil)
        #expect(decoded.cpuTemperatureC == nil)
        let summary = try JSONDecoder().decode(HomeDeviceResourceSummary.self, from: data)
        #expect(summary.gpuPercent == nil)
        #expect(summary.gpuTemperatureC == nil)
    }

    @Test func `html escapes device names`() {
        let listed = HomeDeviceList(devices: [
            HomeDevice(hostId: "self", role: "self", displayName: "A<B>&\"C"),
        ])
        let report = HomeDeviceHealthAggregator.report(
            listed: listed,
            local: HomeDeviceLiveFacts(displayName: "A<B>&\"C"),
            members: [:],
        )
        let html = DisplayHomePage.html(report: report)
        #expect(html.contains("A&lt;B&gt;&amp;&quot;C"))
        #expect(!html.contains("A<B>"))
    }
}
