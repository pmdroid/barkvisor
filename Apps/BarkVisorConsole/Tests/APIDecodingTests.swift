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

    @Test func deviceURLNormalizesHostAndPort() throws {
        let url = try DeviceURL.normalize("192.168.1.20")
        #expect(url.scheme == "http")
        #expect(url.host == "192.168.1.20")
        #expect(url.port == 7777)
        #expect(try DeviceURL.normalize("http://home.local:7777/").absoluteString == "http://home.local:7777")
        #expect(
            try DeviceURL.normalize("http://192.168.30.1:7777/login").absoluteString
                == "http://192.168.30.1:7777"
        )
    }
}
