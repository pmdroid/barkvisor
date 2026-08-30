import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("WorkloadCreationProgress")
struct WorkloadCreationProgressTests {
    @Test func `downloading uses overlay percent`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "downloading", percent: 42),
            lastProgress: event(status: "downloading", percent: 42),
        )
        #expect(progress.phase == .downloading)
        #expect(progress.percent == 42)
    }

    @Test func `downloading with unknown total leaves percent null`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "downloading", percent: nil),
            lastProgress: event(status: "downloading", percent: nil),
        )
        #expect(progress.phase == .downloading)
        #expect(progress.percent == nil)
    }

    @Test func `decompressing follows image progress status`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "decompressing", percent: nil),
            lastProgress: event(status: "decompressing", percent: nil),
        )
        #expect(progress.phase == .decompressing)
        #expect(progress.percent == nil)
    }

    @Test func `ready overlay with provision task is provisioning`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "ready", percent: nil),
            lastProgress: event(status: "ready", percent: 100),
            provisionTaskStatus: .running,
        )
        #expect(progress.phase == .provisioning)
        #expect(progress.percent == nil)
    }

    @Test func `disk clone task without overlay is provisioning`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            provisionTaskStatus: .running,
        )
        #expect(progress.phase == .provisioning)
    }

    @Test func `queued template deploy task is provisioning`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            provisionTaskStatus: .queued,
        )
        #expect(progress.phase == .provisioning)
    }

    @Test func `completed task while still provisioning stays provisioning`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "ready", percent: nil),
            lastProgress: event(status: "ready", percent: 100),
            provisionTaskStatus: .completed,
        )
        #expect(progress.phase == .provisioning)
    }

    @Test func `provisioning with no overlay or task is initiating`() {
        let progress = WorkloadCreationProgressProjector.project(vmState: "provisioning")
        #expect(progress.phase == .initiating)
        #expect(progress.percent == nil)
    }

    @Test func `pending overlay without progress is initiating`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: nil, percent: nil),
        )
        #expect(progress.phase == .initiating)
    }

    @Test func `stopped workload is created`() {
        let progress = WorkloadCreationProgressProjector.project(vmState: "stopped")
        #expect(progress.phase == .created)
    }

    @Test func `running workload is created`() {
        let progress = WorkloadCreationProgressProjector.project(vmState: "running")
        #expect(progress.phase == .created)
    }

    @Test func `starting without pending create is created`() {
        let progress = WorkloadCreationProgressProjector.project(vmState: "starting")
        #expect(progress.phase == .created)
    }

    @Test func `error state is failed`() {
        let progress = WorkloadCreationProgressProjector.project(vmState: "error")
        #expect(progress.phase == .failed)
    }

    @Test func `image status error is failed`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "error", percent: nil),
            imageStatus: "error",
        )
        #expect(progress.phase == .failed)
    }

    @Test func `last progress error is failed`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            overlay: overlay(status: "downloading", percent: 10),
            lastProgress: event(status: "error", percent: nil, error: "checksum"),
        )
        #expect(progress.phase == .failed)
    }

    @Test func `provision task failed is failed`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            provisionTaskStatus: .failed,
        )
        #expect(progress.phase == .failed)
    }

    @Test func `provision task cancelled is failed`() {
        let progress = WorkloadCreationProgressProjector.project(
            vmState: "provisioning",
            provisionTaskStatus: .cancelled,
        )
        #expect(progress.phase == .failed)
    }

    @Test func `provision task ids cover disk clone and template deploy`() {
        #expect(
            WorkloadCreationProgressProjector.provisionTaskIDs(vmID: "vm-1")
                == ["disk-clone:vm-1", "template-deploy:vm-1"],
        )
    }

    @Test func `vm response get path encodes downloading progress`() throws {
        let vm = fixtureVM(state: "provisioning")
        let response = VMResponse(
            from: vm,
            pendingImageId: "img-1",
            downloadPercent: 18,
            lastProgress: event(status: "downloading", percent: 18),
            imageStatus: "downloading",
        )
        #expect(response.creationProgress.phase == .downloading)
        #expect(response.creationProgress.percent == 18)
        #expect(response.pendingImageId == "img-1")
        #expect(response.downloadPercent == 18)
        let dict = try json(response)
        let progress = dict["creationProgress"] as? [String: Any]
        #expect(progress?["phase"] as? String == "downloading")
        #expect(progress?["percent"] as? Int == 18)
    }

    @Test func `create 202 response projects provisioning`() throws {
        let vm = fixtureVM(state: "provisioning")
        let accepted = VMTaskAcceptedResponse(
            taskID: "disk-clone:vm-1",
            vm: VMResponse(from: vm, provisionTaskStatus: .running),
        )
        #expect(accepted.vm.creationProgress.phase == .provisioning)
        let dict = try json(accepted)
        let nested = dict["vm"] as? [String: Any]
        let progress = nested?["creationProgress"] as? [String: Any]
        #expect(progress?["phase"] as? String == "provisioning")
    }

    @Test func `template deploy 202 downloading includes creation progress`() throws {
        let vm = fixtureVM(state: "provisioning")
        let body = DeployTemplateResponse(
            status: "downloading",
            imageId: "img-1",
            taskID: nil,
            vm: VMResponse(
                from: vm,
                pendingImageId: "img-1",
                downloadPercent: 7,
                lastProgress: event(status: "downloading", percent: 7),
                imageStatus: "downloading",
            ),
        )
        #expect(body.vm?.creationProgress.phase == .downloading)
        #expect(body.vm?.creationProgress.percent == 7)
        let dict = try json(body)
        let nested = dict["vm"] as? [String: Any]
        let progress = nested?["creationProgress"] as? [String: Any]
        #expect(progress?["phase"] as? String == "downloading")
    }

    @Test func `template deploy 202 provisioning includes creation progress`() throws {
        let vm = fixtureVM(state: "provisioning")
        let body = DeployTemplateResponse(
            status: "provisioning",
            imageId: nil,
            taskID: "template-deploy:vm-1",
            vm: VMResponse(from: vm, provisionTaskStatus: .running),
        )
        #expect(body.vm?.creationProgress.phase == .provisioning)
        let dict = try json(body)
        let nested = dict["vm"] as? [String: Any]
        let progress = nested?["creationProgress"] as? [String: Any]
        #expect(progress?["phase"] as? String == "provisioning")
    }
}

private func overlay(status: String?, percent: Int?) -> PendingVMImageOverlay {
    PendingVMImageOverlay(pendingImageId: "img-1", downloadPercent: percent, imageStatus: status)
}

private func event(status: String, percent: Int?, error: String? = nil) -> ImageProgressEvent {
    ImageProgressEvent(
        id: "img-1",
        status: status,
        bytesReceived: Int64(percent ?? 0),
        totalBytes: percent == nil ? nil : 100,
        percent: percent,
        error: error,
    )
}

private func fixtureVM(state: String) -> VM {
    VM(
        id: "vm-1",
        name: "pending",
        vmType: "linux-arm64",
        state: state,
        cpuCount: 2,
        memoryMb: 1_024,
        bootDiskId: "disk-1",
        networkId: nil,
        cloudInitPath: nil,
        description: nil,
        bootOrder: nil,
        displayResolution: nil,
        additionalDiskIds: nil,
        uefi: true,
        tpmEnabled: false,
        macAddress: nil,
        sharedPaths: nil,
        portForwards: nil,
        autoCreated: false,
        pendingChanges: false,
        createdAt: "2025-01-01T00:00:00Z",
        updatedAt: "2025-01-01T00:00:00Z",
    )
}

private func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}
