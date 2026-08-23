import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Ollama completion routing (PAS-269)")
struct OllamaRouterTests {
    private func location(
        hostId: String,
        running: Bool,
        memoryTotalMB: Int,
        memoryUsedMB: Int,
        cpuLoadPercent: Double,
        reachable: Bool = true,
        probedAt: String,
    ) -> OllamaModelLocation {
        OllamaModelLocation(
            hostId: hostId,
            displayName: hostId,
            running: running,
            reachable: reachable,
            probedAt: probedAt,
            size: 1_000,
            memoryTotalMB: memoryTotalMB,
            memoryUsedMB: memoryUsedMB,
            cpuLoadPercent: cpuLoadPercent,
        )
    }

    @Test func `prefers already-running then healthier box and never sprays`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let probed = iso8601.string(from: now)
        let runningTight = location(
            hostId: "running-tight",
            running: true,
            memoryTotalMB: 8_192,
            memoryUsedMB: 7_000,
            cpuLoadPercent: 80,
            probedAt: probed,
        )
        let idleHealthy = location(
            hostId: "idle-healthy",
            running: false,
            memoryTotalMB: 32_768,
            memoryUsedMB: 2_048,
            cpuLoadPercent: 5,
            probedAt: probed,
        )
        let picked = OllamaRouter.pick(
            model: "llama3",
            locations: [idleHealthy, runningTight],
            now: now,
        )
        #expect(picked?.hostId == "running-tight")
    }

    @Test func `when none running picks more free memory then lower cpu`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let probed = iso8601.string(from: now)
        let busy = location(
            hostId: "busy",
            running: false,
            memoryTotalMB: 16_384,
            memoryUsedMB: 12_000,
            cpuLoadPercent: 70,
            probedAt: probed,
        )
        let idle = location(
            hostId: "idle",
            running: false,
            memoryTotalMB: 16_384,
            memoryUsedMB: 2_000,
            cpuLoadPercent: 8,
            probedAt: probed,
        )
        let picked = OllamaRouter.pick(model: "phi3", locations: [busy, idle], now: now)
        #expect(picked?.hostId == "idle")
    }

    @Test func `unreachable and stale locations are not routed`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = iso8601.string(from: now)
        let stale = iso8601.string(from: now.addingTimeInterval(-200))
        let down = location(
            hostId: "down",
            running: true,
            memoryTotalMB: 32_768,
            memoryUsedMB: 1_000,
            cpuLoadPercent: 1,
            reachable: false,
            probedAt: fresh,
        )
        let quiet = location(
            hostId: "quiet",
            running: true,
            memoryTotalMB: 32_768,
            memoryUsedMB: 1_000,
            cpuLoadPercent: 1,
            probedAt: stale,
        )
        #expect(OllamaRouter.pick(model: "llama3", locations: [down, quiet], now: now) == nil)
    }

    @Test func `router uses catalog model name and a single host`() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let probed = iso8601.string(from: now)
        let loc = location(
            hostId: "only",
            running: false,
            memoryTotalMB: 8_192,
            memoryUsedMB: 1_024,
            cpuLoadPercent: 3,
            probedAt: probed,
        )
        let catalog = OllamaHomeCatalog(
            anyReachable: true,
            anyInstalled: true,
            models: [
                OllamaCatalogModel(name: "llama3:latest", running: false, locations: [loc]),
            ],
        )
        #expect(OllamaRouter.pick(model: "llama3", catalog: catalog, now: now)?.hostId == "only")
        #expect(OllamaRouter.pick(model: "missing", catalog: catalog, now: now) == nil)
        #expect(OllamaHomeMap.needsProbe(model: "llama3", catalog: catalog, now: now) == false)
        #expect(OllamaHomeMap.needsProbe(model: "missing", catalog: catalog, now: now) == true)
        #expect(OllamaHomeMap.needsProbe(model: "llama3", catalog: nil, now: now) == true)
    }
}
