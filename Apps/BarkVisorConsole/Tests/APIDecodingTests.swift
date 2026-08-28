import Foundation
import Security
import Testing
@testable import BarkVisorConsole

struct APIDecodingTests {
    private let decoder = JSONDecoder()

    @Test func `disk settings snapshot decodes directory`() throws {
        let json = """
        { "diskDirectory": "/var/lib/barkvisor/disks", "isDefault": true }
        """.data(using: .utf8)!
        let settings = try decoder.decode(DiskSettingsSnapshot.self, from: json)
        #expect(settings.diskDirectory == "/var/lib/barkvisor/disks")
        #expect(settings.isDefault)
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/SettingsView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("Default VM disk directory"))
        #expect(source.contains("DiskDirectorySection"))
        #expect(source.contains("refreshDiskSettings"))
    }

    @Test func `remote access status decodes advertised hosts`() throws {
        let json = """
        {
          "tailscale": { "available": true, "ip": "100.64.0.8", "dnsName": "box.tailnet.ts.net" },
          "wireguard": { "configured": false },
          "deviceUrl": "box.tailnet.ts.net",
          "advertisedHosts": ["box.tailnet.ts.net", "100.64.0.8", "192.168.0.8"]
        }
        """.data(using: .utf8)!
        let status = try decoder.decode(RemoteAccessStatus.self, from: json)
        #expect(status.deviceUrl == "box.tailnet.ts.net")
        #expect(status.advertisedHosts == ["box.tailnet.ts.net", "100.64.0.8", "192.168.0.8"])
        #expect(status.tailscale.available)
        #expect(
            PairingAdvertisedHost.syncAdvertisePicker(
                deviceUrl: status.deviceUrl,
                listedHosts: status.advertisedHosts,
            ) == .init(selectedHost: "box.tailnet.ts.net", customHost: ""),
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(
            RemoteAccessUpdate(deviceUrl: "192.168.0.8"),
        )
        let object = try decoder.decode(RemoteAccessUpdateJSON.self, from: body)
        #expect(object.deviceUrl == "192.168.0.8")
    }

    @Test func `remote access status defaults advertised hosts when omitted`() throws {
        let json = """
        {
          "tailscale": { "available": false },
          "wireguard": { "configured": false }
        }
        """.data(using: .utf8)!
        let status = try decoder.decode(RemoteAccessStatus.self, from: json)
        #expect(status.advertisedHosts.isEmpty)
        #expect(status.deviceUrl == nil)
    }

    @Test func `home device health report decodes`() throws {
        let json = """
        {
          "devices": [
            {
              "hostId": "dev-self",
              "role": "self",
              "displayName": "Studio Mac",
              "fingerprint": "abc",
              "agentHost": "127.0.0.1",
              "agentPort": 7778,
              "pairedAt": null,
              "reachability": "ok",
              "collectedAt": "2026-08-14T12:00:00Z",
              "platform": { "os": "macOS", "arch": "arm64" },
              "resources": {
                "cpuCount": 10,
                "memoryTotalMB": 32768,
                "memoryUsedMB": 8192,
                "cpuLoadPercent": 12.5
              },
              "workloadCount": 2,
              "healthCounts": { "running": 1, "stopped": 1, "failed": 0 }
            },
            {
              "hostId": "dev-peer",
              "role": "member",
              "displayName": "Living Room",
              "agentPort": 7778,
              "reachability": "unreachable",
              "reachabilityError": "Device is unreachable"
            }
          ],
          "totals": {
            "devices": 2,
            "reachable": 1,
            "unreachable": 1,
            "workloadCount": 2,
            "healthCounts": { "running": 1, "stopped": 1 }
          }
        }
        """.data(using: .utf8)!

        let report = try decoder.decode(HomeDeviceHealthReport.self, from: json)
        #expect(report.devices.count == 2)
        #expect(report.devices[0].isSelf)
        #expect(report.devices[0].isReachable)
        #expect(report.devices[0].title == "Studio Mac")
        #expect(report.devices[0].workloadLine == "2 workloads")
        #expect(report.devices[1].isReachable == false)
        #expect(report.devices[1].workloadLine == "Health unavailable")
        #expect(report.totals.reachable == 1)
        #expect(report.totals.workloadCount == 2)
    }

    @Test func `workload list uses memory MB and health`() throws {
        let json = """
        [
          {
            "id": "vm-1",
            "name": "haos",
            "vmType": "linux-arm64",
            "state": "running",
            "health": "guest_ready",
            "cpuCount": 2,
            "memoryMB": 2048,
            "bootDiskId": "disk-1",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z",
            "status": { "state": "running", "health": "guest_ready" }
          },
          {
            "id": "vm-2",
            "name": "stopped-box",
            "vmType": "linux-x86_64",
            "state": "stopped",
            "cpuCount": 1,
            "memoryMB": 512,
            "bootDiskId": "disk-2",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-02T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!

        let workloads = try decoder.decode([Workload].self, from: json)
        #expect(workloads.count == 2)
        #expect(workloads[0].memoryMB == 2_048)
        #expect(workloads[0].resolvedHealth == "guest_ready")
        #expect(workloads[0].canStop)
        #expect(workloads[0].pendingImageId == nil)
        #expect(workloads[0].downloadPercent == nil)
        #expect(workloads[1].resolvedHealth == "stopped")
        #expect(workloads[1].canStart)
    }

    @Test func `workload decodes pending image fields`() throws {
        let json = """
        {
          "id": "vm-1",
          "name": "pending",
          "vmType": "linux-arm64",
          "state": "provisioning",
          "cpuCount": 2,
          "memoryMB": 2048,
          "bootDiskId": "disk-1",
          "createdAt": "2026-01-01T00:00:00Z",
          "updatedAt": "2026-01-02T00:00:00Z",
          "pendingImageId": "img-1",
          "downloadPercent": 37
        }
        """.data(using: .utf8)!
        let workload = try decoder.decode(Workload.self, from: json)
        #expect(workload.pendingImageId == "img-1")
        #expect(workload.downloadPercent == 37)
    }

    @Test func `error envelope and setup status decode`() throws {
        let errorJSON = """
        {"error":true,"code":"bad_request","reason":"setup_required","status":503}
        """.data(using: .utf8)!
        let body = try decoder.decode(APIErrorBody.self, from: errorJSON)
        #expect(body.reason == "setup_required")
        #expect(body.status == 503)

        let setup = try decoder.decode(SetupStatus.self, from: Data(#"{"complete":false,"joined":true}"#.utf8))
        #expect(setup.complete == false)
        #expect(setup.joined == true)
    }

    @Test func `device URL requires scheme and normalizes port`() throws {
        #expect(throws: APIError.invalidURL) {
            try DeviceURL.normalize("192.168.1.20")
        }
        #expect(throws: APIError.invalidURL) {
            try DeviceURL.normalize("ftp://home.local:7777")
        }
        let url = try DeviceURL.normalize("https://192.168.1.20")
        #expect(url.scheme == "https")
        #expect(url.host == "192.168.1.20")
        #expect(url.port == 7_777)
        #expect(try DeviceURL.normalize("http://home.local:7777/").absoluteString == "http://home.local:7777")
        #expect(
            try DeviceURL.normalize("http://192.168.30.1:7777/login").absoluteString
                == "http://192.168.30.1:7777",
        )
        #expect(
            try DeviceURL.normalize("http://192.168.30.1:7777/arbitrary/path").absoluteString
                == "http://192.168.30.1:7777",
        )
    }

    @Test func `device URL migrates legacy scheme less stored value`() throws {
        #expect(DeviceURL.migrateStored("192.168.1.20") == "http://192.168.1.20")
        #expect(DeviceURL.migrateStored("  home.local:7777 ") == "http://home.local:7777")
        #expect(DeviceURL.migrateStored("http://192.168.1.20") == "http://192.168.1.20")
        #expect(DeviceURL.migrateStored("https://home.local:7777") == "https://home.local:7777")
        #expect(
            try DeviceURL.normalize(DeviceURL.migrateStored("192.168.1.20")).absoluteString
                == "http://192.168.1.20:7777",
        )
    }

    @Test func `device URL same origin ignores path`() throws {
        let session = try DeviceURL.normalize("http://192.168.30.1:7777/login")
        let same = try DeviceURL.normalize("http://192.168.30.1:7777/settings")
        let otherHost = try DeviceURL.normalize("http://192.168.30.2:7777")
        let otherScheme = try DeviceURL.normalize("https://192.168.30.1:7777")
        #expect(DeviceURL.sameOrigin(session, same))
        #expect(!DeviceURL.sameOrigin(session, otherHost))
        #expect(!DeviceURL.sameOrigin(session, otherScheme))
    }

    @Test func `pairing expiry ticks from expires at`() {
        let expiresAt = "2026-08-16T22:10:00.000Z"
        let issued = iso("2026-08-16T22:00:00.000Z")
        #expect(PairingExpiry.remainingSeconds(expiresAt: expiresAt, now: issued) == 600)
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: issued) == "Expires in 10 minutes")
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: issued.addingTimeInterval(9 * 60)) == "Expires in 1 minute")
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: iso("2026-08-16T22:10:00.000Z")) == "Expired")
        #expect(PairingExpiry.label(expiresAt: "not-a-date", now: issued) == "Expired")
    }

    @Test func `member workload links open device page`() throws {
        let base = try DeviceURL.normalize("http://192.168.30.1:7777")
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "dev-peer", role: "member")
        #expect(
            WorkloadWebLink.page(base: base, workloadID: "vm-1", device: selfDevice).absoluteString
                == "http://192.168.30.1:7777/vms/vm-1",
        )
        #expect(
            WorkloadWebLink.console(base: base, workloadID: "vm-1", device: selfDevice).absoluteString
                == "http://192.168.30.1:7777/vms/vm-1/vnc",
        )
        #expect(
            WorkloadWebLink.page(base: base, workloadID: "vm-1", device: member).absoluteString
                == "http://192.168.30.1:7777/devices/dev-peer",
        )
        #expect(
            WorkloadWebLink.console(base: base, workloadID: "vm-1", device: member).absoluteString
                == "http://192.168.30.1:7777/devices/dev-peer",
        )
    }

    @Test func `home union merges reachable workloads and keeps unreachable explicit`() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: true)
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room", reachable: true)
        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        let haos = workload(id: "vm-1", name: "haos")
        let nas = workload(id: "vm-2", name: "nas")

        let merged = HomeWorkloadUnion.build(
            devices: [studio, living, garage],
            loads: [
                studio.hostId: .success([haos, nas]),
                living.hostId: .failure("Device timed out"),
            ] as [String: HomeWorkloadUnion.Load],
        )

        #expect(merged.rows.map(\.id) == ["self/vm-1", "self/vm-2"])
        #expect(merged.rows.map(\.device.title) == ["Studio", "Studio"])
        #expect(merged.loadErrors.map(\.device.hostId) == ["peer"])
        #expect(merged.loadErrors.first?.message == "Device timed out")
        #expect(merged.unreachable.map(\.hostId) == ["down"])
        #expect(!merged.rows.contains { $0.device.hostId == "down" })
    }

    @Test func `home union does not invent rows when load is missing`() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: true)
        let merged = HomeWorkloadUnion.build(devices: [studio], loads: [:])
        #expect(merged.rows.isEmpty)
        #expect(merged.loadErrors.isEmpty)
        #expect(merged.unreachable.isEmpty)
    }

    @Test func `devices tab badge counts unreachable paired devices`() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: true)
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room", reachable: false)
        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        #expect(DevicesTabBadge.count(in: []) == 0)
        #expect(DevicesTabBadge.count(in: [studio]) == 0)
        #expect(DevicesTabBadge.count(in: [snapshot(hostId: "self", role: "self", reachable: false)]) == 1)
        #expect(DevicesTabBadge.count(in: [studio, living]) == 1)
        #expect(DevicesTabBadge.count(in: [studio, living, garage]) == 2)
        #expect(DevicesTabBadge.count(in: [living, garage]) == 2)
        let listed = HomeDevice(
            hostId: "peer",
            role: "member",
            fingerprint: nil,
            displayName: "Living Room",
            agentHost: nil,
            agentPort: 7_778,
            pairedAt: nil,
        )
        #expect(DevicesTabBadge.count(in: [listed.asSnapshot]) == 0)
        let union = HomeWorkloadUnion.build(
            devices: [studio, living, garage],
            loads: [studio.hostId: .success([])],
        )
        #expect(DevicesTabBadge.count(in: [studio, living, garage]) == union.unreachable.count)
    }

    @Test func `api key routes use auth keys not bare keys`() {
        #expect(APIKeyRoutes.collection == "/api/auth/keys")
        #expect(APIKeyRoutes.item("k1") == "/api/auth/keys/k1")
        #expect(!APIKeyRoutes.collection.hasPrefix("/api/keys"))
        #expect(APIKeyKindOption.createDefault == .inference)
        #expect(APIKeyKindOption.badge("full") == "full")
        #expect(APIKeyKindOption.badge(nil) == "inference")
        #expect(APIKeyKindOption.badge("mystery") == "inference")
    }

    @Test func `api key list decodes without secret`() throws {
        let json = """
        {
          "id": "k1",
          "name": "ollama-cli",
          "keyPrefix": "barkvisor_abcde",
          "expiresAt": "2027-06-15T00:00:00Z",
          "lastUsedAt": "2026-08-01T12:30:00Z",
          "createdAt": "2026-01-01T00:00:00Z",
          "kind": "inference",
          "key": "barkvisor_abcdeSECRET"
        }
        """.data(using: .utf8)!
        let key = try decoder.decode(APIKeyResponse.self, from: json)
        #expect(key.id == "k1")
        #expect(key.name == "ollama-cli")
        #expect(key.keyPrefix == "barkvisor_abcde")
        #expect(key.kindBadge == "inference")
        #expect(key.expiresAt == "2027-06-15T00:00:00Z")
        #expect(key.lastUsedAt == "2026-08-01T12:30:00Z")
        #expect(!key.hasSecretField)
        #expect(
            APIKeyDisplay.expiryLabel(key.expiresAt, now: iso("2026-08-01T00:00:00.000Z")) == "2027-06-15",
        )
        #expect(APIKeyDisplay.expiryLabel(nil) == "Never")
        #expect(
            APIKeyDisplay.expiryLabel("2020-01-01T00:00:00Z", now: iso("2026-01-01T00:00:00.000Z")) == "Expired",
        )
        #expect(APIKeyDisplay.usedLabel(nil) == "Never")
        #expect(APIKeyDisplay.usedLabel(key.lastUsedAt) == "2026-08-01 12:30")
        #expect(APIKeyDisplay.createdLabel(key.createdAt) == "2026-01-01")
    }

    @Test func `api key create decodes secret once and defaults kind`() throws {
        let json = """
        {
          "id": "k2",
          "name": "ci",
          "key": "barkvisor_live_secret",
          "keyPrefix": "barkvisor_live_",
          "expiresAt": null,
          "createdAt": "2026-02-02T00:00:00Z"
        }
        """.data(using: .utf8)!
        let created = try decoder.decode(APIKeyCreateResponse.self, from: json)
        #expect(created.key == "barkvisor_live_secret")
        #expect(created.kind == "full")
        #expect(created.expiresAt == nil)
        let missingKindList = """
        {
          "id": "k3",
          "name": "legacy",
          "keyPrefix": "barkvisor_legac",
          "expiresAt": null,
          "lastUsedAt": null,
          "createdAt": "2026-01-01T00:00:00Z"
        }
        """.data(using: .utf8)!
        let listed = try decoder.decode(APIKeyResponse.self, from: missingKindList)
        #expect(listed.kindBadge == "full")
        #expect(
            APIKeyDisplay.forbiddenMessage(from: APIError.http(status: 403, reason: "forbidden"))
                == "forbidden",
        )
        #expect(
            APIKeyDisplay.forbiddenMessage(from: APIError.http(status: 403, reason: "  "))
                == APIKeyDisplay.forbiddenFallback,
        )
        #expect(APIKeyDisplay.forbiddenMessage(from: APIError.unauthorized) == nil)
        #expect(APIKeyDisplay.inferenceCopy == "inference = Ollama list + chat completions only")
        #expect(APIKeyDisplay.signInRequired == "Sign in required")
        #expect(APIKeyDisplay.signInRequired == APIError.unauthorized.errorDescription)
    }

    @Test func `api key display reuses cached ISO8601 formatters`() {
        let fractional = "2026-08-01T12:30:00.000Z"
        let whole = "2026-08-01T12:30:00Z"
        let parsedFractional = APIKeyDisplay.parseISO8601(fractional)
        let parsedWhole = APIKeyDisplay.parseISO8601(whole)
        #expect(parsedFractional != nil)
        #expect(parsedWhole != nil)
        #expect(APIKeyDisplay.parseISO8601(fractional) == parsedFractional)
        #expect(APIKeyDisplay.parseISO8601(whole) == parsedWhole)
        #expect(APIKeyDisplay.parseISO8601("not-a-date") == nil)
        #expect(APIKeyDisplay.createdLabel(fractional) == "2026-08-01")
        #expect(APIKeyDisplay.createdLabel(whole) == "2026-08-01")
        #expect(APIKeyDisplay.usedLabel(fractional) == "2026-08-01 12:30")
        #expect(APIKeyDisplay.usedLabel(whole) == "2026-08-01 12:30")
    }

    @Test func `minted api key keychain round trip does not touch session jwt`() {
        let account = "test-minted-api-key-\(UUID().uuidString)"
        let secret = "barkvisor_live_roundtrip"
        let previousJWT = KeychainStore.readToken()
        defer {
            _ = KeychainStore.delete(account: account)
        }
        #expect(account != KeychainStore.tokenAccount)
        #expect(account != KeychainStore.refreshAccount)
        let status = KeychainStore.saveStatus(account: account, value: secret)
        #expect(status == errSecSuccess)
        #expect(KeychainStore.read(account: account) == secret)
        #expect(KeychainStore.readToken() == previousJWT)
        #expect(KeychainStore.delete(account: account))
        #expect(KeychainStore.read(account: account) == nil)
        #expect(KeychainStore.readToken() == previousJWT)
    }

    @Test func `home device directory does not mask non 404`() throws {
        #expect(try HomeDeviceDirectory.resolution(healthStatus: nil, listStatus: nil, aboutSucceeded: true) == .health)
        #expect(try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: nil, aboutSucceeded: true) == .registry)
        #expect(
            try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: 404, aboutSucceeded: true) == .preHome,
        )
        #expect(throws: APIError.http(status: 500, reason: "Device health request failed")) {
            try HomeDeviceDirectory.resolution(healthStatus: 500, listStatus: nil, aboutSucceeded: true)
        }
        #expect(throws: APIError.http(status: 503, reason: "Device list request failed")) {
            try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: 503, aboutSucceeded: true)
        }
        #expect(throws: APIError.http(status: 404, reason: "Home Device list is unavailable")) {
            try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: 404, aboutSucceeded: false)
        }
    }

    @Test func `system about decodes version platform arch accelerator uptime`() throws {
        let json = """
        {
          "version": "0.4.0",
          "platform": "macOS",
          "hostArch": "arm64",
          "accelerator": "hvf",
          "processUptimeSeconds": 42,
          "licenses": [
            {
              "name": "QEMU",
              "license": "GPL-2.0",
              "url": "https://www.qemu.org/",
              "description": "Machine emulator"
            }
          ]
        }
        """.data(using: .utf8)!
        let about = try decoder.decode(SystemAbout.self, from: json)
        #expect(about.version == "0.4.0")
        #expect(about.platform == "macOS")
        #expect(about.hostArch == "arm64")
        #expect(about.accelerator == "hvf")
        #expect(about.processUptimeSeconds == 42)
    }

    @Test func `system about decode fails without uptime`() throws {
        let json = """
        {
          "version": "0.4.0",
          "platform": "Linux",
          "hostArch": "x86_64",
          "accelerator": "kvm"
        }
        """.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try decoder.decode(SystemAbout.self, from: json)
        }
    }

    @Test func `system capabilities decodes gpu passthrough`() throws {
        let macos = """
        {
          "platform": "macOS",
          "supportsBridgedNetworking": true,
          "supportsManagedBridgeDaemon": true,
          "supportsUSBPassthrough": true,
          "supportsInAppUpdate": true,
          "supportsGPUPassthrough": false,
          "supportsVFIO": false,
          "accelerator": "hvf",
          "hostArch": "arm64",
          "details": [
            {
              "code": "gpuPassthrough",
              "supported": false,
              "reasonCode": "os_unsupported",
              "remediation": "GPU passthrough is not available on macOS. Use a Linux Device with IOMMU, vfio-pci, and KVM."
            }
          ]
        }
        """.data(using: .utf8)!
        let caps = try decoder.decode(SystemCapabilities.self, from: macos)
        #expect(!caps.gpuPassthroughSupported)
        #expect(caps.gpuPassthroughExplanation.contains("macOS"))
        #expect(!caps.gpuPassthroughExplanation.localizedCaseInsensitiveContains("node"))
        #expect(!caps.gpuPassthroughExplanation.localizedCaseInsensitiveContains("cluster"))

        let linux = """
        {
          "platform": "Linux",
          "supportsGPUPassthrough": true,
          "supportsVFIO": true,
          "details": [{ "code": "gpuPassthrough", "supported": true }]
        }
        """.data(using: .utf8)!
        let ready = try decoder.decode(SystemCapabilities.self, from: linux)
        #expect(ready.gpuPassthroughSupported)
        #expect(ready.gpuPassthroughExplanation.contains(GPUPassthroughCopy.guestOllamaPath))
        #expect(ready.gpuPassthroughExplanation.contains("same card cannot be host and guest"))
    }

    @Test func `host gpu device decodes iommu group and guest ollama path`() throws {
        let json = """
        {
          "id": "0000:01:00.0",
          "pciAddress": "0000:01:00.0",
          "iommuGroup": "14",
          "vendorId": "10de",
          "deviceId": "2684",
          "name": "NVIDIA 2684 (nvidia)",
          "attachable": true,
          "inUseByHost": false,
          "guestOllamaPath": "http://127.0.0.1:11434/v1",
          "groupAddresses": ["0000:01:00.0", "0000:01:00.1"],
          "claimedByVMId": null,
          "claimedByVMName": null
        }
        """.data(using: .utf8)!
        let gpu = try decoder.decode(HostGPUDevice.self, from: json)
        #expect(gpu.pciAddress == "0000:01:00.0")
        #expect(gpu.iommuGroup == "14")
        #expect(gpu.canAttach)
        #expect(gpu.guestOllamaPath == GPUPassthroughCopy.guestOllamaPath)
        #expect(gpu.occupancyCopy == nil)
        #expect(
            GPUPassthroughCopy.groupMatesLabel(
                pciAddress: gpu.pciAddress, groupAddresses: gpu.groupAddresses,
            ) == "0000:01:00.1",
        )
        #expect(GPUPassthroughCopy.singleDisplayWarning.contains("one GPU"))
        #expect(GPUPassthroughCopy.groupMatesLabel(pciAddress: "0000:01:00.0", groupAddresses: nil) == "none")

        let busyJSON = """
        {
          "id": "0000:01:00.0",
          "pciAddress": "0000:01:00.0",
          "iommuGroup": "14",
          "vendorId": "10de",
          "deviceId": "2684",
          "name": "NVIDIA",
          "attachable": true,
          "inUseByHost": true
        }
        """.data(using: .utf8)!
        let busy = try decoder.decode(HostGPUDevice.self, from: busyJSON)
        #expect(busy.canAttach)
        #expect(busy.occupancyCopy == "In use by host")
    }

    @Test func `host usb device attach requires persistable serial`() throws {
        let serialJSON = """
        {
          "id": "0x1234:0x5678:ZX9",
          "vendorId": "0x1234",
          "productId": "0x5678",
          "name": "Probe",
          "manufacturer": "Acme",
          "serialNumber": "ZX9",
          "bus": 3,
          "address": 2,
          "idUnstable": false,
          "attachable": true,
          "claimedByVMId": null,
          "claimedByVMName": null
        }
        """.data(using: .utf8)!
        let serial = try decoder.decode(HostUSBDevice.self, from: serialJSON)
        #expect(serial.canAttach)
        #expect(serial.occupancyCopy == nil)

        let busJSON = """
        {
          "id": "bus:001.002",
          "vendorId": "0x1234",
          "productId": "0x5678",
          "name": "Stick",
          "manufacturer": null,
          "serialNumber": null,
          "idUnstable": true,
          "attachable": true,
          "claimedByVMId": null,
          "claimedByVMName": null
        }
        """.data(using: .utf8)!
        let bus = try decoder.decode(HostUSBDevice.self, from: busJSON)
        #expect(!bus.canAttach)
        #expect(bus.occupancyCopy == USBPassthroughCopy.noSerial)
    }

    @Test func `gpu detach is only allowed when the workload is stopped`() {
        #expect(!workload(id: "vm-1", name: "gpu").canDetachGPU)
        #expect(!workload(id: "vm-1", name: "gpu", state: "starting").canDetachGPU)
        #expect(workload(id: "vm-1", name: "gpu", state: "stopped").canDetachGPU)
        #expect(workload(id: "vm-1", name: "gpu", state: "error").canDetachGPU)
        #expect(!workload(id: "vm-1", name: "usb").canDetachUSB)
        #expect(workload(id: "vm-1", name: "usb", state: "stopped").canDetachUSB)
    }

    @Test func `gpu passthrough copy prefers server remediation`() {
        let text = GPUPassthroughCopy.explanation(
            supported: false,
            remediation: "IOMMU is not active (0 IOMMU groups).",
            platform: "Linux",
        )
        #expect(text.contains("IOMMU"))
        #expect(
            GPUPassthroughCopy.explanation(supported: false, remediation: nil, platform: "macOS")
                .contains("macOS"),
        )
        let kvm = GPUPassthroughCopy.explanation(
            supported: false,
            remediation: "GPU passthrough needs KVM (/dev/kvm). Install qemu-kvm, add this user to the kvm group, or enable nested virtualization, then confirm /dev/kvm exists.",
            platform: "Linux",
        )
        #expect(kvm.contains("qemu-kvm"))
        #expect(kvm.localizedCaseInsensitiveContains("nested"))
        #expect(!kvm.localizedCaseInsensitiveContains("node"))
        #expect(!kvm.localizedCaseInsensitiveContains("cluster"))
    }

    private func iso(_ raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)!
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

    private func workload(id: String, name: String, state: String = "running") -> Workload {
        Workload(
            id: id,
            name: name,
            vmType: "linux-arm64",
            state: state,
            health: "running",
            cpuCount: 2,
            memoryMB: 1_024,
            bootDiskId: "disk-1",
            isoId: nil,
            isoIds: nil,
            networkId: nil,
            description: nil,
            pendingChanges: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
            status: nil,
            portForwards: nil,
            gpuDevices: nil,
        )
    }
}

private struct RemoteAccessUpdateJSON: Decodable {
    var deviceUrl: String
}
