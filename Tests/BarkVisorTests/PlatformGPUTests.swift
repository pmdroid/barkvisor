import Foundation
import Testing
@testable import BarkVisorCore

struct PlatformGPUTests {
    @Test func `apple performance statistics use device utilization`() {
        let percent = PlatformGPU.percent(fromPerformanceStatistics: [
            "Device Utilization %": 37,
            "Renderer Utilization %": 12,
            "In use system memory": 94_552_064,
        ])
        #expect(percent == 37)
    }

    @Test func `gpu busy percentage is a fallback key`() {
        let percent = PlatformGPU.percent(fromPerformanceStatistics: [
            "gpu-busy-percentage": 8.5,
        ])
        #expect(percent == 8.5)
    }

    @Test func `missing accelerator stats are nil not zero`() {
        #expect(PlatformGPU.percent(fromPerformanceStatistics: ["In use system memory": 1]) == nil)
        #expect(PlatformGPU.percent(fromPerformanceStatistics: [:]) == nil)
    }

    @Test func `linux nvidia busy percent is used as-is`() {
        var state: (ms: UInt64, at: Date)?
        let percent = PlatformGPU.linuxBusyPercent(
            now: Date(),
            snapshot: PlatformGPU.LinuxSnapshot(gpuBusyPercent: 41, rc6ResidencyMs: 1_000, actFreqMHz: 300),
            state: &state,
        )
        #expect(percent == 41)
    }

    @Test func `linux i915 idle act freq is zero busy`() {
        var state: (ms: UInt64, at: Date)?
        let percent = PlatformGPU.linuxBusyPercent(
            now: Date(),
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 1_000, actFreqMHz: 0),
            state: &state,
        )
        #expect(percent == 0)
    }

    @Test func `linux i915 rc6 delta is busy percent`() {
        var state: (ms: UInt64, at: Date)?
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = t0.addingTimeInterval(5)
        #expect(
            PlatformGPU.linuxBusyPercent(
                now: t0,
                snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 10_000, actFreqMHz: 300),
                state: &state,
            ) == nil,
        )
        let percent = PlatformGPU.linuxBusyPercent(
            now: t1,
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 10_000 + 1_000, actFreqMHz: 300),
            state: &state,
        )
        #expect(percent == 80)
    }

    @Test func `linux rc6 counter reset is unknown not 100`() {
        var state: (ms: UInt64, at: Date)?
        let t0 = Date(timeIntervalSince1970: 3_000)
        let t1 = t0.addingTimeInterval(1)
        _ = PlatformGPU.linuxBusyPercent(
            now: t0,
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 80_000, actFreqMHz: 300),
            state: &state,
        )
        let percent = PlatformGPU.linuxBusyPercent(
            now: t1,
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 100, actFreqMHz: 300),
            state: &state,
        )
        #expect(percent == nil)
        #expect(state?.ms == 100)
    }

    @Test func `linux fully rc6 is idle`() {
        var state: (ms: UInt64, at: Date)?
        let t0 = Date(timeIntervalSince1970: 2_000)
        let t1 = t0.addingTimeInterval(1)
        _ = PlatformGPU.linuxBusyPercent(
            now: t0,
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 50_000, actFreqMHz: 200),
            state: &state,
        )
        let percent = PlatformGPU.linuxBusyPercent(
            now: t1,
            snapshot: PlatformGPU.LinuxSnapshot(rc6ResidencyMs: 51_000, actFreqMHz: 200),
            state: &state,
        )
        #expect(percent == 0)
    }

    @Test func `stats sample encodes gpu null not zero`() throws {
        let sample = SystemStatsSample(
            timestamp: "2026-08-24T23:00:00Z",
            hostCpuPercent: 10,
            hostMemoryUsedMB: 1_024,
            hostMemoryTotalMB: 8_192,
            hostGpuPercent: nil,
        )
        let encoded = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SystemStatsSample.self, from: encoded)
        #expect(decoded.hostGpuPercent == nil)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect((object?["hostGpuPercent"] as? Double) != 0)
        let busy = SystemStatsSample(
            timestamp: "2026-08-24T23:00:05Z",
            hostCpuPercent: 10,
            hostMemoryUsedMB: 1_024,
            hostMemoryTotalMB: 8_192,
            hostGpuPercent: 12.5,
        )
        let decodedBusy = try JSONDecoder().decode(SystemStatsSample.self, from: JSONEncoder().encode(busy))
        #expect(decodedBusy.hostGpuPercent == 12.5)
    }
}
