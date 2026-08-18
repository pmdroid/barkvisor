import Foundation
import Testing
@testable import BarkVisorConsole

struct WorkloadDetailTests {
    private let decoder = JSONDecoder()

    @Test func guestInfoDecodesOsAndAddresses() throws {
        let json = """
        {
          "available": true,
          "ipAddresses": ["192.168.64.12", "fe80::1"],
          "osName": "Ubuntu",
          "osVersion": "24.04",
          "hostname": "haos"
        }
        """.data(using: .utf8)!

        let guest = try decoder.decode(GuestInfo.self, from: json)
        #expect(guest.available)
        #expect(guest.osLabel == "Ubuntu 24.04")
        #expect(guest.primaryIP == "192.168.64.12")
        #expect(WorkloadGuestSummary.ipLabel(guest: guest) == "192.168.64.12")
    }

    @Test func guestInfoKeepsNatFallbackAddressWhenAgentMissing() throws {
        let json = """
        {
          "available": false,
          "ipAddresses": ["10.0.2.15"],
          "ipSource": "nat-default"
        }
        """.data(using: .utf8)!

        let guest = try decoder.decode(GuestInfo.self, from: json)
        #expect(!guest.available)
        #expect(guest.osLabel == nil)
        #expect(WorkloadGuestSummary.ipLabel(guest: guest) == "10.0.2.15")
    }

    @Test func guestSummaryFallsBackToVmTypeFamily() {
        let linux = fixtureWorkload(vmType: "linux-arm64")
        let windows = fixtureWorkload(id: "vm-win", name: "desktop", vmType: "windows-x86_64")
        #expect(WorkloadGuestSummary.osLabel(workload: linux, guest: nil) == "Linux")
        #expect(WorkloadGuestSummary.osLabel(workload: windows, guest: nil) == "Windows")
        #expect(WorkloadGuestSummary.ipLabel(guest: nil) == nil)

        let guest = GuestInfo(available: true, ipAddresses: [], osName: "Fedora", osVersion: nil)
        #expect(WorkloadGuestSummary.osLabel(workload: linux, guest: guest) == "Fedora")
    }

    @Test func memberConsoleAndDisplayStayDisabled() {
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: false, state: "running") == .memberDisabled)
        #expect(!WorkloadStreamAccess.resolve(isSelfDevice: false, state: "running").allowsOpen)
        #expect(
            WorkloadStreamAccess.memberDisabled.reason
                == "Console and Display on a member Device are not available yet."
        )
    }

    @Test func thisDeviceConsoleOpensOnlyWhenLive() {
        #expect(WorkloadStream.isLive("running"))
        #expect(WorkloadStream.isLive("stopping"))
        #expect(!WorkloadStream.isLive("stopped"))
        #expect(!WorkloadStream.isLive("starting"))
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "running") == .available)
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "stopping") == .available)
        #expect(WorkloadStreamAccess.resolve(isSelfDevice: true, state: "stopped") == .notLive)
        #expect(!WorkloadStreamAccess.resolve(isSelfDevice: true, state: "stopped").allowsOpen)
        #expect(WorkloadStreamAccess.notLive.reason == "The Workload must be running.")
    }

    @Test func detailIdentityKeepsDeviceAndWorkloadTogether() {
        let studio = snapshot(hostId: "self", role: "self", title: "Studio")
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        let haos = fixtureWorkload(id: "vm-1", name: "haos")
        let row = HomeWorkloadRow(workload: haos, device: living)
        #expect(row.id == "peer/vm-1")
        #expect(studio.isSelf)
        #expect(!living.isSelf)
        #expect(HomeDeviceHealthSnapshot.placeholderSelf.isSelf)
        #expect(HomeDeviceHealthSnapshot.placeholderSelf.title == "This Device")
    }

    @Test func actionKeyMatchesHomeRowAndFallsBackToBareID() {
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        let haos = fixtureWorkload(id: "vm-1", name: "haos")
        #expect(WorkloadActionKey.id(hostID: "self", workloadID: "vm-1") == "self/vm-1")
        #expect(WorkloadActionKey.id(hostID: "peer", workloadID: "vm-1") == "peer/vm-1")
        #expect(WorkloadActionKey.id(hostID: nil, workloadID: "vm-1") == "vm-1")
        #expect(WorkloadActionKey.id(hostID: "", workloadID: "vm-1") == "vm-1")
        #expect(
            HomeWorkloadRow(workload: haos, device: living).id
                == WorkloadActionKey.id(hostID: "peer", workloadID: "vm-1")
        )
    }

    @Test func guestInfoStopsRetryAfterSuccessfulResponse() {
        let missing = GuestInfo(available: false, ipAddresses: ["10.0.2.15"])
        let ready = GuestInfo(available: true, ipAddresses: ["192.168.64.12"], osName: "Ubuntu")
        #expect(GuestInfoRefresh.shouldRetry(guest: nil, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: missing, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: ready, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: nil, running: false))
        #expect(!GuestInfoRefresh.shouldRetry(guest: missing, running: false))
        #expect(!GuestInfoRefresh.shouldRetry(guest: nil, running: true, reachable: false))
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

    private func fixtureWorkload(
        id: String = "vm-1",
        name: String = "haos",
        vmType: String = "linux-arm64",
        state: String = "running"
    ) -> Workload {
        Workload(
            id: id,
            name: name,
            vmType: vmType,
            state: state,
            health: state == "running" ? "guest_ready" : nil,
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
