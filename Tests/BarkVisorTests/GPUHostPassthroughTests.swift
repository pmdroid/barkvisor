import Foundation
import Testing

struct GPUHostPassthroughTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `feature allows host GPU passthrough without warning`() throws {
        let feature = try read("features/gpu-host-passthrough.feature")
        #expect(feature.contains("This machine lists one GPU"))
        #expect(feature.contains("In use by host"))
        #expect(feature.contains("Host GPU driver"))
        #expect(feature.contains("Device"))
        #expect(feature.contains("Workload"))
        #expect(feature.contains("does not disable Attach"))
    }

    @Test func `web GPU copy has no single-GPU warning or In use by host`() throws {
        let files = [
            "frontend/src/utils/gpuPassthrough.ts",
            "frontend/src/views/VMDetailView.vue",
        ]
        for path in files {
            let source = try read(path)
            #expect(!source.contains("This machine lists one GPU"))
            #expect(!source.contains("blank the host display"))
            #expect(!source.contains("In use by host"))
            #expect(!source.contains("GPU_SINGLE_DISPLAY_WARNING"))
            #expect(!source.contains("singleGPUDisplay"))
        }
        let copy = try read("frontend/src/utils/gpuPassthrough.ts")
        #expect(copy.contains("Host GPU driver"))
        let view = try read("frontend/src/views/VMDetailView.vue")
        #expect(view.contains("gpuHostOccupancyLabel"))
        #expect(view.contains("dev.claimedByVMId || dev.attachable === false"))
        #expect(!view.contains("dev.inUseByHost ||"))
        #expect(!view.contains("inUseByHost ? 'opacity"))
    }

    @Test func `console GPU copy has no single-GPU warning or In use by host`() throws {
        let files = [
            "Apps/BarkVisorConsole/Sources/Models/Models.swift",
            "Apps/BarkVisorConsole/Sources/Views/WorkloadDetailView.swift",
            "Apps/BarkVisorConsole/Sources/Views/DeviceDetailView.swift",
        ]
        for path in files {
            let source = try read(path)
            #expect(!source.contains("This machine lists one GPU"))
            #expect(!source.contains("blank the host display"))
            #expect(!source.contains("In use by host"))
            #expect(!source.contains("singleDisplayWarning"))
        }
        let models = try read("Apps/BarkVisorConsole/Sources/Models/Models.swift")
        #expect(models.contains("Host GPU driver"))
        #expect(models.contains("attachable == true && claimedByVMId == nil"))
        let workload = try read("Apps/BarkVisorConsole/Sources/Views/WorkloadDetailView.swift")
        #expect(workload.contains("busy || !gpu.canAttach"))
        #expect(!workload.contains("inUseByHost"))
    }
}
