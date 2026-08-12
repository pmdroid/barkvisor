import Foundation
import Testing
@testable import BarkVisorCore

@Suite("HostMetrics")
struct HostMetricsTests {
    private static let testHostId = "22222222-2222-2222-2222-222222222222"

    private func inventory() -> HostInventory {
        HostInventoryService.snapshot(hostId: Self.testHostId)
    }

    @Test func `projects inventory resources and storage`() {
        let inv = inventory()
        let metrics = HostMetrics.from(
            inventory: inv,
            capture: HostMetricsCapture(temperatureC: nil, uptimeSeconds: 42, agentHealthy: true),
        )
        #expect(metrics.hostId == inv.hostId)
        #expect(metrics.collectedAt == inv.collectedAt)
        #expect(metrics.cpuLoadPercent == inv.resources.cpuLoadPercent)
        #expect(metrics.memoryTotalMB == inv.resources.memoryTotalMB)
        #expect(metrics.memoryUsedMB == inv.resources.memoryUsedMB)
        #expect(metrics.storage == inv.storage)
        #expect(metrics.storage.contains { $0.kind == "dataDir" })
        #expect(metrics.temperatureC == nil)
        #expect(metrics.uptimeSeconds == 42)
        #expect(metrics.agentHealthy)
        // Parity: same probes inventory uses (do not hardcode host cpuCount/arch).
        #expect(metrics.memoryTotalMB == PlatformHost.physicalMemoryMB)
    }

    @Test func `encodes missing temperature as json null not zero`() throws {
        let metrics = HostMetrics.from(
            inventory: inventory(),
            capture: HostMetricsCapture(temperatureC: nil, uptimeSeconds: 1, agentHealthy: true),
        )
        let data = try JSONEncoder().encode(metrics)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["temperatureC"] is NSNull)
        #expect(object?["temperatureC"] as? Double == nil)
        #expect((object?["temperatureC"] as? Int) != 0)
    }

    @Test func `encodes a real temperature including zero`() throws {
        let zero = HostMetrics.from(
            inventory: inventory(),
            capture: HostMetricsCapture(temperatureC: 0, uptimeSeconds: 1, agentHealthy: true),
        )
        let warm = HostMetrics.from(
            inventory: inventory(),
            capture: HostMetricsCapture(temperatureC: 47.6, uptimeSeconds: 1, agentHealthy: false),
        )
        let zeroObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(zero)) as? [String: Any]
        let warmObj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(warm)) as? [String: Any]
        #expect(zeroObj?["temperatureC"] as? Double == 0)
        #expect(warmObj?["temperatureC"] as? Double == 47.6)
        #expect(warmObj?["agentHealthy"] as? Bool == false)
    }

    @Test func `round trip preserves null temperature`() throws {
        let original = HostMetrics.from(
            inventory: inventory(),
            capture: HostMetricsCapture(temperatureC: nil, uptimeSeconds: 9, agentHealthy: true),
        )
        let decoded = try JSONDecoder().decode(HostMetrics.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.temperatureC == nil)
    }

    @Test func `history minutes clamp to thirty minute ring`() {
        #expect(MetricsCollector.systemStatsRetentionMinutes == 30)
        #expect(MetricsCollector.systemStatsPollIntervalSeconds == 5)
        #expect(MetricsCollector.systemStatsMaxSamples == 360)
        #expect(MetricsCollector.clampSystemStatsMinutes(1_440) == 30)
        #expect(MetricsCollector.clampSystemStatsMinutes(30) == 30)
        #expect(MetricsCollector.clampSystemStatsMinutes(10) == 10)
        #expect(MetricsCollector.clampSystemStatsMinutes(0) == 1)
        #expect(MetricsCollector.clampSystemStatsMinutes(-5) == 1)
    }

    @Test func `thermal milli-celsius parser rejects garbage`() {
        #expect(PlatformHost.parseThermalMilliCelsius("45000\n") == 45.0)
        #expect(PlatformHost.parseThermalMilliCelsius("0") == 0)
        #expect(PlatformHost.parseThermalMilliCelsius("") == nil)
        #expect(PlatformHost.parseThermalMilliCelsius("N/A") == nil)
        #expect(PlatformHost.parseThermalMilliCelsius("not-a-number") == nil)
    }

    @Test func `thermal zone picker prefers cpu pkg and skips bad readings`() {
        let zones: [(type: String, milli: String)] = [
            (type: "acpitz", milli: "30000"),
            (type: "x86_pkg_temp", milli: "52000"),
            (type: "cpu-thermal", milli: "not-a-number"),
        ]
        #expect(PlatformHost.selectLinuxThermalCelsius(zones: zones) == 52.0)

        let onlyBad: [(type: String, milli: String)] = [
            (type: "cpu-thermal", milli: "oops"),
            (type: "acpitz", milli: ""),
        ]
        #expect(PlatformHost.selectLinuxThermalCelsius(zones: onlyBad) == nil)

        let fallback: [(type: String, milli: String)] = [
            (type: "acpitz", milli: "31000"),
        ]
        #expect(PlatformHost.selectLinuxThermalCelsius(zones: fallback) == 31.0)
    }

    @Test func `macos temperature probe is nil without a public sensor api`() {
        #if os(macOS)
            #expect(PlatformHost.temperatureCelsius == nil)
        #endif
    }
}
