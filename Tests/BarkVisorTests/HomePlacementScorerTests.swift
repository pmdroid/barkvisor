import Foundation
import Testing
@testable import BarkVisorCore

@Suite("Home placement scorer (PAS-44)")
struct HomePlacementScorerTests {
    private func device(
        hostId: String,
        role: String = "member",
        reachability: String = HomeDeviceHealthAggregator.ok,
        arch: String? = "arm64",
        memoryTotalMB: Int? = 8_192,
        memoryUsedMB: Int? = 1_024,
        cpuLoadPercent: Double? = 20,
        features: HomeDeviceFeatureSummary? = HomeDeviceFeatureSummary(
            kvmDevice: true, bridgedNetworking: true, usbPassthrough: true,
        ),
        reachabilityError: String? = nil,
    ) -> HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: hostId,
            reachability: reachability,
            reachabilityError: reachabilityError,
            platform: arch.map { HomeDevicePlatformSummary(os: "linux", arch: $0) },
            resources: HomeDeviceResourceSummary(
                cpuCount: 2,
                memoryTotalMB: memoryTotalMB,
                memoryUsedMB: memoryUsedMB,
                cpuLoadPercent: cpuLoadPercent,
            ),
            features: features,
        )
    }

    @Test func `offline and arch and feature and memory are hard fails`() {
        let request = HomePlacementScoreRequest(
            declaredArchitectures: ["arm64"],
            requiredFeatures: ["bridgedNetworking"],
            minMemoryMB: 4_096,
        )
        let down = device(
            hostId: "down",
            reachability: HomeDeviceHealthAggregator.unreachable,
            reachabilityError: "Device is unreachable",
        )
        let x86 = device(hostId: "x86", arch: "x86_64")
        let noBridge = device(
            hostId: "no-bridge",
            features: HomeDeviceFeatureSummary(
                kvmDevice: true, bridgedNetworking: false, usbPassthrough: true,
            ),
        )
        let tight = device(hostId: "tight", memoryTotalMB: 4_096, memoryUsedMB: 3_584)
        let ok = device(hostId: "ok", cpuLoadPercent: 5)
        let scored = HomePlacementScorer.score(
            request: request,
            devices: [down, x86, noBridge, tight, ok],
        )
        #expect(scored.recommendedHostId == "ok")
        #expect(scored.candidates.map(\.hostId) == ["ok", "down", "no-bridge", "x86", "tight"])
        let byId = Dictionary(uniqueKeysWithValues: scored.candidates.map { ($0.hostId, $0) })
        #expect(byId["down"]?.eligible == false)
        #expect(byId["down"]?.reasons.contains { $0.code == HomePlacementScorer.offlineCode } == true)
        #expect(byId["x86"]?.reasons.contains { $0.code == HomePlacementScorer.archMismatchCode } == true)
        #expect(byId["no-bridge"]?.reasons.contains { $0.code == HomePlacementScorer.featureMissingCode } == true)
        #expect(byId["tight"]?.reasons.contains { $0.code == HomePlacementScorer.memoryCode } == true)
        #expect(byId["ok"]?.eligible == true)
        #expect(byId["ok"]?.recommended == true)
        #expect(byId["ok"]?.reasons.contains { $0.kind == HomePlacementScorer.softKind } == true)
        #expect(byId["ok"]?.reasons.contains { $0.message.contains("free memory") } == true)
    }

    @Test func `self stays eligible when every peer is unreachable`() {
        let selfDev = device(hostId: "self", role: "self", cpuLoadPercent: 10)
        let peer = device(
            hostId: "peer",
            reachability: HomeDeviceHealthAggregator.unreachable,
        )
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(declaredArchitectures: ["arm64"], minMemoryMB: 512),
            devices: [selfDev, peer],
        )
        #expect(scored.recommendedHostId == "self")
        #expect(scored.candidates.first { $0.hostId == "self" }?.eligible == true)
        #expect(scored.candidates.first { $0.hostId == "peer" }?.eligible == false)
    }

    @Test func `soft rank prefers more free memory then lower cpu load`() {
        let busy = device(
            hostId: "busy", memoryTotalMB: 8_192, memoryUsedMB: 6_144, cpuLoadPercent: 80,
        )
        let idle = device(
            hostId: "idle", memoryTotalMB: 8_192, memoryUsedMB: 1_024, cpuLoadPercent: 8,
        )
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(minMemoryMB: 512),
            devices: [busy, idle],
        )
        #expect(scored.recommendedHostId == "idle")
        #expect(scored.candidates.map(\.hostId) == ["idle", "busy"])
        #expect(scored.candidates[0].score > scored.candidates[1].score)
    }

    @Test func `requested memory is a hard floor even without minMemoryMB`() {
        let small = device(hostId: "small", memoryTotalMB: 2_048, memoryUsedMB: 1_024)
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requestedMemoryMB: 2_048),
            devices: [small],
        )
        #expect(scored.recommendedHostId == nil)
        #expect(scored.candidates[0].eligible == false)
        #expect(scored.candidates[0].reasons.contains { $0.code == HomePlacementScorer.memoryCode } == true)
    }

    @Test func `kvm bridged usb aliases match Wave 0 feature codes`() {
        let host = device(
            hostId: "desk",
            features: HomeDeviceFeatureSummary(
                kvmDevice: true, bridgedNetworking: false, usbPassthrough: true,
            ),
        )
        #expect(host.features?.supports("kvm") == true)
        #expect(host.features?.supports("usb") == true)
        #expect(host.features?.supports("bridged") == false)
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requiredFeatures: ["kvm", "usbPassthrough"]),
            devices: [host],
        )
        #expect(scored.recommendedHostId == "desk")
        let missing = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requiredFeatures: ["bridged"]),
            devices: [host],
        )
        #expect(missing.recommendedHostId == nil)
        #expect(missing.candidates[0].reasons.contains { $0.message.contains("bridgedNetworking") } == true)
    }

    @Test func `missing feature snapshot fails closed; unknown feature is not PAS-91 matched`() {
        let noFlags = device(hostId: "blank", features: nil)
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requiredFeatures: ["usbPassthrough"]),
            devices: [noFlags],
        )
        #expect(scored.recommendedHostId == nil)
        #expect(scored.candidates[0].reasons.contains { $0.code == HomePlacementScorer.featureMissingCode } == true)

        let known = device(hostId: "desk")
        let gpu = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requiredFeatures: ["gpu:nvidia"]),
            devices: [known],
        )
        #expect(gpu.recommendedHostId == nil)
        #expect(gpu.candidates[0].reasons.contains { $0.message.contains("gpu:nvidia") } == true)
    }

    @Test func `empty request still ranks reachable Devices and never invents a place`() {
        let a = device(hostId: "a", cpuLoadPercent: 40)
        let b = device(hostId: "b", cpuLoadPercent: 5)
        let scored = HomePlacementScorer.score(request: HomePlacementScoreRequest(), devices: [a, b])
        #expect(scored.recommendedHostId == "b")
        #expect(scored.candidates.contains { !$0.eligible } == false)
        #expect(scored.candidates.count(where: \.recommended) == 1)
    }

    @Test func `encodes missing recommendedHostId as json null`() throws {
        let scored = HomePlacementScorer.score(
            request: HomePlacementScoreRequest(requestedMemoryMB: 65_536),
            devices: [device(hostId: "tight", memoryTotalMB: 2_048, memoryUsedMB: 1_024)],
        )
        #expect(scored.recommendedHostId == nil)
        let data = try JSONEncoder().encode(scored)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["recommendedHostId"] is NSNull)
        #expect(object["candidates"] is [Any])
    }

    @Test func `memoryFloor is the max of min and requested`() {
        #expect(HomePlacementScorer.memoryFloor(request: HomePlacementScoreRequest()) == 0)
        #expect(HomePlacementScorer.memoryFloor(
            request: HomePlacementScoreRequest(minMemoryMB: 512, requestedMemoryMB: 2_048),
        ) == 2_048)
        #expect(HomePlacementScorer.memoryFloor(
            request: HomePlacementScoreRequest(minMemoryMB: 4_096, requestedMemoryMB: 1_024),
        ) == 4_096)
    }
}
