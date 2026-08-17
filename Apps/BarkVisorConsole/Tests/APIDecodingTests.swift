import Foundation
import Testing
@testable import BarkVisorConsole

struct APIDecodingTests {
    private let decoder = JSONDecoder()

    @Test func homeDeviceHealthReportDecodes() throws {
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

    @Test func workloadListUsesMemoryMBAndHealth() throws {
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
        #expect(workloads[0].memoryMB == 2048)
        #expect(workloads[0].resolvedHealth == "guest_ready")
        #expect(workloads[0].canStop)
        #expect(workloads[1].resolvedHealth == "stopped")
        #expect(workloads[1].canStart)
    }

    @Test func errorEnvelopeAndSetupStatusDecode() throws {
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

    @Test func deviceURLRequiresSchemeAndNormalizesPort() throws {
        #expect(throws: APIError.invalidURL) {
            try DeviceURL.normalize("192.168.1.20")
        }
        #expect(throws: APIError.invalidURL) {
            try DeviceURL.normalize("ftp://home.local:7777")
        }
        let url = try DeviceURL.normalize("https://192.168.1.20")
        #expect(url.scheme == "https")
        #expect(url.host == "192.168.1.20")
        #expect(url.port == 7777)
        #expect(try DeviceURL.normalize("http://home.local:7777/").absoluteString == "http://home.local:7777")
        #expect(
            try DeviceURL.normalize("http://192.168.30.1:7777/login").absoluteString
                == "http://192.168.30.1:7777"
        )
    }

    @Test func deviceURLSameOriginIgnoresPath() throws {
        let session = try DeviceURL.normalize("http://192.168.30.1:7777/login")
        let same = try DeviceURL.normalize("http://192.168.30.1:7777/settings")
        let otherHost = try DeviceURL.normalize("http://192.168.30.2:7777")
        let otherScheme = try DeviceURL.normalize("https://192.168.30.1:7777")
        #expect(DeviceURL.sameOrigin(session, same))
        #expect(!DeviceURL.sameOrigin(session, otherHost))
        #expect(!DeviceURL.sameOrigin(session, otherScheme))
    }

    @Test func pairingExpiryTicksFromExpiresAt() throws {
        let expiresAt = "2026-08-16T22:10:00.000Z"
        let issued = iso("2026-08-16T22:00:00.000Z")
        #expect(PairingExpiry.remainingSeconds(expiresAt: expiresAt, now: issued) == 600)
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: issued) == "Expires in 10 minutes")
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: issued.addingTimeInterval(9 * 60)) == "Expires in 1 minute")
        #expect(PairingExpiry.label(expiresAt: expiresAt, now: iso("2026-08-16T22:10:00.000Z")) == "Expired")
        #expect(PairingExpiry.label(expiresAt: "not-a-date", now: issued) == "Expired")
    }

    @Test func memberWorkloadLinksOpenDevicePage() throws {
        let base = try DeviceURL.normalize("http://192.168.30.1:7777")
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "dev-peer", role: "member")
        #expect(
            WorkloadWebLink.page(base: base, workloadID: "vm-1", device: selfDevice).absoluteString
                == "http://192.168.30.1:7777/vms/vm-1"
        )
        #expect(
            WorkloadWebLink.console(base: base, workloadID: "vm-1", device: selfDevice).absoluteString
                == "http://192.168.30.1:7777/vms/vm-1/vnc"
        )
        #expect(
            WorkloadWebLink.page(base: base, workloadID: "vm-1", device: member).absoluteString
                == "http://192.168.30.1:7777/devices/dev-peer"
        )
        #expect(
            WorkloadWebLink.console(base: base, workloadID: "vm-1", device: member).absoluteString
                == "http://192.168.30.1:7777/devices/dev-peer"
        )
    }

    @Test func homeUnionMergesReachableWorkloadsAndKeepsUnreachableExplicit() {
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
            ] as [String: HomeWorkloadUnion.Load]
        )

        #expect(merged.rows.map(\.id) == ["self/vm-1", "self/vm-2"])
        #expect(merged.rows.map(\.device.title) == ["Studio", "Studio"])
        #expect(merged.loadErrors.map(\.device.hostId) == ["peer"])
        #expect(merged.loadErrors.first?.message == "Device timed out")
        #expect(merged.unreachable.map(\.hostId) == ["down"])
        #expect(!merged.rows.contains { $0.device.hostId == "down" })
    }

    @Test func homeUnionDoesNotInventRowsWhenLoadIsMissing() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio", reachable: true)
        let merged = HomeWorkloadUnion.build(devices: [studio], loads: [:])
        #expect(merged.rows.isEmpty)
        #expect(merged.loadErrors.isEmpty)
        #expect(merged.unreachable.isEmpty)
    }

    @Test func homeDeviceDirectoryDoesNotMaskNon404() throws {
        #expect(try HomeDeviceDirectory.resolution(healthStatus: nil, listStatus: nil, aboutSucceeded: true) == .health)
        #expect(try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: nil, aboutSucceeded: true) == .registry)
        #expect(
            try HomeDeviceDirectory.resolution(healthStatus: 404, listStatus: 404, aboutSucceeded: true) == .preHome
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

    private func iso(_ raw: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw)!
    }

    private func snapshot(
        hostId: String,
        role: String,
        title: String? = nil,
        reachable: Bool = true
    ) -> HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: title ?? hostId,
            fingerprint: nil,
            agentHost: nil,
            agentPort: 7777,
            pairedAt: nil,
            reachability: reachable ? "ok" : "unreachable",
            reachabilityError: reachable ? nil : "Device is unreachable",
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil
        )
    }

    private func workload(id: String, name: String) -> Workload {
        Workload(
            id: id,
            name: name,
            vmType: "linux-arm64",
            state: "running",
            health: "running",
            cpuCount: 2,
            memoryMB: 1024,
            bootDiskId: "disk-1",
            isoId: nil,
            networkId: nil,
            description: nil,
            pendingChanges: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
            status: nil
        )
    }
}
