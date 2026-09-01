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
        #expect(points[0].gpuPercent == nil)
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

    @Test func `memberHTTP is HTTP error not Unreachable`() {
        var http = snapshot(hostId: "peer", role: "member", title: "Studio", reachable: false)
        http.reachability = "memberHTTP"
        http.reachabilityError = "Device returned HTTP 503"
        #expect(DeviceReachability.label("memberHTTP") == "HTTP error")
        #expect(DeviceReachability.statusKey("memberHTTP") == "degraded")
        #expect(DeviceReachability.label("connectTimeout") == "Timed out")
        #expect(DeviceReachability.statusKey("connectTimeout") == "failed")
        #expect(http.reachabilityLabel == "HTTP error")
        let pill = StatusLabel.reachability(http)
        #expect(pill.text == "HTTP error")
        #expect(pill.key == "degraded")
        #expect(!pill.text.localizedCaseInsensitiveContains("unreachable"))
        let copy = DeviceStatsHistory.unavailableCopy(http)
        #expect(copy.contains("Device returned HTTP 503"))
        #expect(!copy.contains("did not answer"))

        let down = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        #expect(StatusLabel.reachability(down).text == "Unreachable")
        #expect(DeviceStatsHistory.unavailableCopy(down) == DeviceStatsHistory.unreachableCopy)

        var ok = snapshot(hostId: "ok", role: "member", title: "Office", reachable: true)
        ok.reachability = "ok"
        #expect(DeviceStatsHistory.unavailableCopy(ok) != DeviceStatsHistory.unreachableCopy)
    }

    @Test func `rename is offered on this Device and reachable members only`() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: false)
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room", reachable: true)
        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        #expect(DeviceRename.canRename(studio))
        #expect(DeviceRename.canRename(living))
        #expect(!DeviceRename.canRename(garage))
        #expect(DeviceRename.parse("  Studio Mac  ") == "Studio Mac")
        #expect(DeviceRename.parse("   ") == nil)
        #expect(DeviceRename.parse(String(repeating: "n", count: DeviceRename.maxLength)) != nil)
        #expect(DeviceRename.parse(String(repeating: "n", count: DeviceRename.maxLength + 1)) == nil)
    }

    @Test func `device name path uses local api or home proxy`() throws {
        let client = try APIClient(baseURL: #require(URL(string: "http://127.0.0.1:7777")))
        let studio = snapshot(hostId: "self", role: "self", title: "Studio")
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        #expect(client.scoped("/system/device-name", on: studio) == "/api/system/device-name")
        #expect(
            client.scoped("/system/device-name", on: living)
                == "/api/home/devices/peer/v1/system/device-name",
        )
        let slashMember = snapshot(hostId: "peer/1", role: "member", title: "Slash")
        #expect(
            client.scoped("/system/device-name", on: slashMember)
                == "/api/home/devices/peer%2F1/v1/system/device-name",
        )
    }

    @Test func `device detail offers rename next to the title`() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/DeviceDetailView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("DeviceRename.canRename"))
        #expect(source.contains("Button(\"Rename\")"))
        #expect(source.contains("saveDeviceName"))
        #expect(source.contains("Device name"))
        #expect(source.contains("DeviceRename.canRename(device)"))
        #expect(!source.contains("Guest Ollama"))
        #expect(!source.contains("127.0.0.1:11434"))
        #expect(!source.contains("guestOllamaPath"))
        #expect(source.contains("DiskDirectorySection"))
        #expect(source.contains("Default VM disk directory"))
        #expect(source.contains("saveDiskSettings"))
        #expect(source.contains("FolderPickerView(device: device)"))
        let picker = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/FolderPickerView.swift"),
            encoding: .utf8,
        )
        #expect(picker.contains("if let api = error as? APIError, case .permissionDenied = api, !path.isEmpty"))
        #expect(picker.contains("self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription"))
        #expect(source.contains("guard !directory.isEmpty else { return }"))
        #expect(source.contains("guard device.hostId == host else { return }"))
        #expect(source.contains(".id(device.hostId)"))
        #expect(source.contains(#"task(id: "\(device.hostId)-\(device.isReachable)")"#))
        #expect(source.contains("model.clearDiskSettings(for: device)"))
        #expect(source.contains("model.diskSettings(for: device)?.isDefault != false"))
        #expect(source.contains("if !draft.isEmpty, draft != (model.diskSettings(for: device)?.diskDirectory ?? \"\") { return }"))
        #expect(source.contains("saveDiskSettings(\"\", on: device)"))
        let modelSource = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Services/AppModel.swift"),
            encoding: .utf8,
        )
        #expect(modelSource.contains("diskSettingsHostId"))
        #expect(modelSource.contains("func clearDiskSettings(for device: HomeDeviceHealthSnapshot)"))
        #expect(modelSource.contains("func diskSettings(for device: HomeDeviceHealthSnapshot)"))
        #expect(modelSource.contains("diskSettings = nil\n        diskSettingsHostId = host"))
        #expect(modelSource.contains("guard diskSettingsHostId == host else { return }"))
        #expect(modelSource.contains("guard diskSettingsHostId == nil || diskSettingsHostId == host else { return true }"))
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
        #expect(client.scoped("/system/about", on: nil) == "/api/system/about")
        #expect(client.scoped("/system/about", on: studio) == "/api/system/about")
        #expect(client.scoped("/system/about", on: living) == "/api/home/devices/peer/v1/system/about")
        #expect(client.scoped("/system/capabilities", on: living) == "/api/home/devices/peer/v1/system/capabilities")
        #expect(client.scoped("/system/disk/settings", on: studio) == "/api/system/disk/settings")
        #expect(client.scoped("/system/disk/settings", on: living) == "/api/home/devices/peer/v1/system/disk/settings")
        let slashMember = snapshot(hostId: "peer/1", role: "member", title: "Slash")
        #expect(client.scoped("/system/about", on: slashMember) == "/api/home/devices/peer%2F1/v1/system/about")
        #expect(
            client.scoped("/system/stats/history", on: slashMember)
                == "/api/home/devices/peer%2F1/v1/system/stats/history",
        )
    }

    @Test func `doctor decodes details with reason and remediation`() throws {
        let json = """
        {
          "platform": "Linux",
          "supportsGPUPassthrough": false,
          "details": [
            {
              "code": "kvmDevice",
              "supported": false,
              "reasonCode": "kvm_missing",
              "remediation": "KVM is not available (/dev/kvm missing). Guests run under TCG (software emulation)."
            },
            {
              "code": "tcgOnly",
              "supported": true,
              "reasonCode": "kvm_missing",
              "remediation": "This host is using TCG software emulation (no hardware accelerator)."
            },
            { "code": "usbPassthrough", "supported": true },
            { "code": "futureProbe", "supported": false, "reasonCode": "os_unsupported" }
          ]
        }
        """.data(using: .utf8)!

        let caps = try decoder.decode(SystemCapabilities.self, from: json)
        let rows = DeviceDoctor.rows(from: caps)
        #expect(rows.count == 4)

        let kvm = try #require(caps.detail(code: "kvmDevice"))
        #expect(kvm.supported == false)
        #expect(kvm.reasonCode == "kvm_missing")
        #expect(kvm.remediation?.contains("/dev/kvm") == true)
        #expect(DeviceDoctor.title(for: kvm.code) == "KVM device")
        #expect(DeviceDoctor.statusLabel(supported: kvm.supported) == "Not supported")
        #expect(DeviceDoctor.note(for: kvm)?.contains("/dev/kvm") == true)

        // tcgOnly is supported yet degraded: the server note still shows.
        let tcg = try #require(caps.detail(code: "tcgOnly"))
        #expect(tcg.supported)
        #expect(DeviceDoctor.title(for: tcg.code) == "TCG software emulation")
        #expect(DeviceDoctor.statusLabel(supported: tcg.supported) == "Supported")
        #expect(DeviceDoctor.note(for: tcg)?.contains("TCG") == true)

        let usb = try #require(caps.detail(code: "usbPassthrough"))
        #expect(DeviceDoctor.note(for: usb) == nil)

        // Unknown codes fall back to the raw code so new server rows still render.
        #expect(DeviceDoctor.title(for: "futureProbe") == "futureProbe")
        #expect(DeviceDoctor.note(for: try #require(caps.detail(code: "futureProbe"))) == nil)
    }

    @Test func `doctor path uses local api or home proxy`() throws {
        let client = try APIClient(baseURL: #require(URL(string: "http://127.0.0.1:7777")))
        let studio = snapshot(hostId: "self", role: "self", title: "Studio")
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        #expect(client.scoped("/system/capabilities", on: nil) == "/api/system/capabilities")
        #expect(client.scoped("/system/capabilities", on: studio) == "/api/system/capabilities")
        #expect(
            client.scoped("/system/capabilities", on: living)
                == "/api/home/devices/peer/v1/system/capabilities",
        )
        let slashMember = snapshot(hostId: "peer/1", role: "member", title: "Slash")
        #expect(
            client.scoped("/system/capabilities", on: slashMember)
                == "/api/home/devices/peer%2F1/v1/system/capabilities",
        )
    }

    @Test func `unreachable device skips doctor fetch`() {
        let garage = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: false)
        // Same rule as stats: unreachable members skip the capabilities fetch.
        #expect(!DeviceStatsHistory.shouldFetch(garage))
        #expect(DeviceStatsHistory.shouldFetch(studio))
        // No capabilities document means no doctor rows, never invented ones.
        #expect(DeviceDoctor.rows(from: nil).isEmpty)
        #expect(DeviceDoctor.rows(from: SystemCapabilities(platform: "Linux")).isEmpty)
    }

    @Test func `device detail lists doctor rows from capabilities details`() throws {
        let tests = URL(fileURLWithPath: #filePath)
        let source = try String(
            contentsOf: tests.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/DeviceDetailView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("Section(\"Doctor\")"))
        #expect(source.contains("DeviceDoctor.rows(from: deviceCaps)"))
        #expect(source.contains("DeviceDoctor.note(for: detail)"))
        #expect(!source.contains("system/doctor"))
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

    @Test func `stats history maps gpu percent without inventing zero`() throws {
        let json = """
        [
          {
            "timestamp": "2026-08-24T12:00:00Z",
            "hostCpuPercent": 1,
            "hostMemoryUsedMB": 1024,
            "hostMemoryTotalMB": 8192,
            "hostGpuPercent": 18.5
          }
        ]
        """.data(using: .utf8)!
        let samples = try decoder.decode([SystemStatsSample].self, from: json)
        #expect(samples[0].hostGpuPercent == 18.5)
        let points = DeviceStatsHistory.points(from: samples)
        #expect(points[0].gpuPercent == 18.5)
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
