import Foundation
import Testing
@testable import BarkVisorConsole

struct CreateWorkloadTests {
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    @Test func `ready images ignore downloading and error`() {
        let images = [
            image(id: "b", name: "Beta", status: "downloading"),
            image(id: "a", name: "Alpha", status: "ready"),
            image(id: "c", name: "Gamma", status: "error"),
            image(id: "d", name: "Delta", status: "READY"),
        ]
        let ready = CreateWorkload.ready(images)
        #expect(ready.map(\.id) == ["a", "d"])
        #expect(CreateWorkload.hasReadyImage(images))
        #expect(!CreateWorkload.hasReadyImage([image(id: "x", name: "x", status: "downloading")]))
        #expect(!CreateWorkload.canSubmit(name: "box", image: images[0]))
        #expect(CreateWorkload.canSubmit(name: " box ", image: images[1]))
        #expect(!CreateWorkload.canSubmit(name: "   ", image: images[1]))
        #expect(!CreateWorkload.canSubmit(name: "box", image: images[1], loadingImages: true))
    }

    @Test func `windows installer names are not classified as linux`() throws {
        #expect(CreateWorkload.osFamily(fromName: "Windows 11") == "windows")
        #expect(CreateWorkload.osFamily(fromName: "Win11_English_x64.iso") == "windows")
        #expect(CreateWorkload.osFamily(fromName: "Win10_22H2_English_x64.iso") == "windows")
        #expect(CreateWorkload.osFamily(fromName: "Win8.1_English_x64.iso") == "windows")
        #expect(CreateWorkload.osFamily(fromName: "en-us_windows_11_consumer_x64.iso") == "windows")
        #expect(CreateWorkload.osFamily(fromName: "Ubuntu 24.04") == "linux")
        #expect(CreateWorkload.osFamily(fromName: "alpine-virt-3.23.3-aarch64.iso") == "linux")
        #expect(CreateWorkload.osFamily(fromName: "Fedora-KDE-Live-x86_64.iso") == "linux")
        #expect(CreateWorkload.osFamily(fromName: "virtio-win-0.1.240.iso") == "linux")

        let installer = try CreateWorkload.body(
            name: "winbox",
            image: image(id: "iso-w", name: "Win11_English_x64.iso", imageType: "iso", arch: "x86_64"),
            hostCPUCount: 8,
        )
        #expect(installer.osFamily == "windows")
        #expect(installer.vmType == "windows-amd64")
        #expect(installer.memoryMB == 4_096)
        #expect(installer.diskSizeGB == 64)
        #expect(installer.isoId == "iso-w")
    }

    @Test func `stale library fetch is not applied`() {
        #expect(CreateWorkload.shouldApplyLibraryLoad(loadID: 2, currentID: 2, cancelled: false))
        #expect(!CreateWorkload.shouldApplyLibraryLoad(loadID: 1, currentID: 2, cancelled: false))
        #expect(!CreateWorkload.shouldApplyLibraryLoad(loadID: 2, currentID: 2, cancelled: true))
    }

    @Test func `reachable device key changes with membership`() {
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "peer-1", role: "member")
        var down = snapshot(hostId: "peer-2", role: "member")
        down.reachability = "unreachable"
        #expect(CreateWorkload.reachableDeviceKey([selfDevice, member, down]) == "peer-1\nself")
        #expect(CreateWorkload.reachableDeviceKey([selfDevice, member]) == "peer-1\nself")
        #expect(CreateWorkload.reachableDeviceKey([selfDevice]) != CreateWorkload.reachableDeviceKey([selfDevice, member]))
    }

    @Test func `resolved device does not fall back after deviceID is set`() {
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "peer-1", role: "member")
        #expect(
            CreateWorkload.resolvedDevice(
                deviceID: "",
                reachable: [selfDevice, member],
                selected: selfDevice,
            )?.hostId == "self",
        )
        #expect(
            CreateWorkload.resolvedDevice(
                deviceID: "peer-1",
                reachable: [selfDevice, member],
                selected: selfDevice,
            )?.hostId == "peer-1",
        )
        #expect(
            CreateWorkload.resolvedDevice(
                deviceID: "peer-1",
                reachable: [selfDevice],
                selected: selfDevice,
            ) == nil,
        )
    }

    @Test func `guest type comes from image arch not host`() {
        #expect(CreateWorkload.guestType(osFamily: "linux", arch: "aarch64") == "linux-arm64")
        #expect(CreateWorkload.guestType(osFamily: "linux", arch: "arm64") == "linux-arm64")
        #expect(CreateWorkload.guestType(osFamily: "linux", arch: "amd64") == "linux-amd64")
        #expect(CreateWorkload.guestType(osFamily: "linux", arch: "x86_64") == "linux-amd64")
        #expect(CreateWorkload.guestType(osFamily: "windows", arch: "arm64") == "windows-arm64")
        #expect(CreateWorkload.guestType(osFamily: "windows", arch: "x86_64") == "windows-amd64")
        #expect(CreateWorkload.normalizedArch("x86-64") == "x86_64")
    }

    @Test func `cpu defaults clamp to provided host count`() throws {
        let linux = image(id: "img-l", name: "Ubuntu 24.04", imageType: "cloud-image", arch: "arm64")
        let windows = image(id: "img-w", name: "Windows 11", imageType: "iso", arch: "x86_64")

        let linuxBody = try CreateWorkload.body(name: "haos", image: linux, hostCPUCount: 8)
        #expect(linuxBody.osFamily == "linux")
        #expect(linuxBody.vmType == "linux-arm64")
        #expect(linuxBody.cpuCount == 2)
        #expect(linuxBody.memoryMB == 1_024)
        #expect(linuxBody.diskSizeGB == 10)
        #expect(linuxBody.cloudImageId == "img-l")
        #expect(linuxBody.isoId == nil)
        #expect(linuxBody.workloadClass == nil)
        #expect(linuxBody.cloudInit == nil)

        let agentBody = try CreateWorkload.body(
            name: "cage",
            image: linux,
            hostCPUCount: 8,
            workloadClass: "agent",
        )
        #expect(agentBody.workloadClass == "agent")

        let clamped = try CreateWorkload.body(name: "tiny", image: linux, hostCPUCount: 1)
        #expect(clamped.cpuCount == 1)

        let unknownHost = try CreateWorkload.body(name: "haos", image: linux, hostCPUCount: nil)
        #expect(unknownHost.cpuCount == 2)

        let winBody = try CreateWorkload.body(name: "win", image: windows, hostCPUCount: 8)
        #expect(winBody.osFamily == "windows")
        #expect(winBody.vmType == "windows-amd64")
        #expect(winBody.cpuCount == 4)
        #expect(winBody.memoryMB == 4_096)
        #expect(winBody.diskSizeGB == 64)
        #expect(winBody.isoId == "img-w")
        #expect(winBody.cloudImageId == nil)
    }

    @Test func `body omits network and encodes cloud or ISO`() throws {
        let cloud = try CreateWorkload.body(
            name: "  nas  ",
            image: image(id: "cloud-1", name: "Debian", imageType: "cloud-image", arch: "x86_64"),
            hostCPUCount: 4,
        )
        let cloudJSON = try json(cloud)
        #expect(cloudJSON["name"] as? String == "nas")
        #expect(cloudJSON["vmType"] as? String == "linux-amd64")
        #expect(cloudJSON["cloudImageId"] as? String == "cloud-1")
        #expect(cloudJSON["isoId"] == nil)
        #expect(cloudJSON["networkId"] == nil)
        #expect((cloudJSON["cpuCount"] as? NSNumber)?.intValue == 2)

        let iso = try CreateWorkload.body(
            name: "installer",
            image: image(id: "iso-1", name: "Ubuntu Desktop", imageType: "iso", arch: "arm64"),
            hostCPUCount: 4,
        )
        let isoJSON = try json(iso)
        #expect(isoJSON["isoId"] as? String == "iso-1")
        #expect(isoJSON["cloudImageId"] == nil)
        #expect(isoJSON["vmType"] as? String == "linux-arm64")
    }

    @Test func `coding agent image defaults to agent class and device ollama`() throws {
        let coding = image(id: "img-ca", name: "Coding Agent", imageType: "cloud-image", arch: "arm64")
        #expect(CodingAgentImage.matches(name: coding.name))
        #expect(CodingAgentImage.matches(name: "Ubuntu", slug: "coding-agent-x86_64"))
        #expect(!CodingAgentImage.matches(name: "Ubuntu 24.04 LTS", slug: "ubuntu-24.04-arm64"))
        #expect(!CodingAgentImage.matches(name: "my coding agent lab"))
        #expect(!CodingAgentImage.matches(name: "Coding Agent", slug: "ubuntu-24.04-arm64"))
        #expect(CodingAgentImage.defaultClass(forName: coding.name) == "agent")
        #expect(CodingAgentImage.defaultClass(forName: "Ubuntu 24.04 LTS") == "house")

        let body = try CreateWorkload.body(name: "coder", image: coding, hostCPUCount: 8)
        #expect(body.workloadClass == "agent")
        #expect(body.memoryMB == 2_048)
        #expect(body.diskSizeGB == 20)
        #expect(body.cloudImageId == "img-ca")
        #expect(body.cloudInit?.userData?.contains("OPENAI_BASE_URL='http://10.0.2.2:11434/v1'") == true)
        #expect(body.cloudInit?.userData?.contains("git") == true)
        #expect(body.cloudInit?.userData?.contains("ttyd") == true)
        #expect(body.cloudInit?.userData?.contains("ttyd.service") == true)
        #expect(body.cloudInit?.userData?.contains("sha256sum -c") == true)
        #expect(body.cloudInit?.userData?.contains("claude.ai/install.sh") == true)

        let ubuntu = image(id: "img-u", name: "Ubuntu 24.04 LTS", imageType: "cloud-image", arch: "arm64")
        let afterSwitch = try CreateWorkload.body(
            name: "coder",
            image: ubuntu,
            hostCPUCount: 8,
            workloadClass: CodingAgentImage.defaultClass(forName: ubuntu.name),
        )
        #expect(afterSwitch.workloadClass == nil)
        #expect(afterSwitch.memoryMB == 1_024)
        #expect(afterSwitch.diskSizeGB == 10)
        #expect(afterSwitch.cloudInit == nil)

        let encoded = try json(body)
        #expect(encoded["workloadClass"] as? String == "agent")
        let cloudInit = encoded["cloudInit"] as? [String: Any]
        #expect((cloudInit?["userData"] as? String)?.contains("10.0.2.2:11434") == true)

        let byo = try CreateWorkload.body(
            name: "coder",
            image: coding,
            hostCPUCount: 8,
            openaiBaseURL: "https://api.example/v1",
        )
        #expect(byo.cloudInit?.userData?.contains("https://api.example/v1") == true)

        let house = try CreateWorkload.body(
            name: "coder",
            image: coding,
            hostCPUCount: 8,
            workloadClass: "house",
        )
        #expect(house.workloadClass == "house")

        #expect(throws: CreateWorkload.DraftError.invalidOpenAIBaseURL) {
            try CreateWorkload.body(
                name: "coder",
                image: coding,
                hostCPUCount: 8,
                openaiBaseURL: "not a url",
            )
        }
        #expect(throws: CreateWorkload.DraftError.invalidOpenAIBaseURL) {
            try CreateWorkload.body(
                name: "coder",
                image: coding,
                hostCPUCount: 8,
                openaiBaseURL: "https://x$(reboot).example/v1",
            )
        }
    }

    @Test func `body rejects empty name and unread image`() {
        let ready = image(id: "img-1", name: "Ubuntu", status: "ready")
        let downloading = image(id: "img-2", name: "Ubuntu", status: "downloading")
        #expect(throws: CreateWorkload.DraftError.emptyName) {
            try CreateWorkload.body(name: "  ", image: ready, hostCPUCount: 2)
        }
        #expect(throws: CreateWorkload.DraftError.imageNotReady) {
            try CreateWorkload.body(name: "box", image: downloading, hostCPUCount: 2)
        }
    }

    @Test func `create accepted 202 decodes workload`() throws {
        let json = """
        {
          "taskID": "task-9",
          "vm": {
            "id": "vm-9",
            "name": "nas",
            "vmType": "linux-amd64",
            "state": "provisioning",
            "cpuCount": 2,
            "memoryMB": 1024,
            "bootDiskId": "disk-9",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
          }
        }
        """.data(using: .utf8)!
        let accepted = try decoder.decode(CreateWorkloadAccepted.self, from: json)
        #expect(accepted.taskID == "task-9")
        #expect(accepted.vm.id == "vm-9")
        #expect(accepted.vm.name == "nas")
        #expect(accepted.vm.state == "provisioning")
    }

    @Test func `member create uses home proxy path`() throws {
        let api = try APIClient(baseURL: #require(URL(string: "http://192.168.30.1:7777")), token: "t")
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "peer-1", role: "member")
        #expect(api.scoped("/vms", on: selfDevice) == "/api/vms")
        #expect(api.scoped("/vms", on: nil) == "/api/vms")
        #expect(api.scoped("/vms", on: member) == "/api/home/devices/peer-1/v1/vms")
    }

    private func json(_ body: CreateWorkload.Body) throws -> [String: Any] {
        let data = try encoder.encode(body)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dict = object as? [String: Any] else {
            Issue.record("encoded body was not an object")
            return [:]
        }
        return dict
    }

    private func image(
        id: String,
        name: String,
        imageType: String = "cloud-image",
        arch: String = "arm64",
        status: String = "ready",
    ) -> LibraryImage {
        LibraryImage(
            id: id,
            name: name,
            imageType: imageType,
            arch: arch,
            status: status,
            sizeBytes: 1_024,
            sourceUrl: nil,
            error: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
    }

    private func snapshot(hostId: String, role: String) -> HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: hostId,
            fingerprint: nil,
            agentHost: nil,
            agentPort: 7_777,
            pairedAt: nil,
            reachability: "ok",
            reachabilityError: nil,
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }
}
