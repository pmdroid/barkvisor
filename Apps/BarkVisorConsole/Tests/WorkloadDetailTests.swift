import Foundation
import Testing
@testable import BarkVisorConsole

struct WorkloadDetailTests {
    private let decoder = JSONDecoder()

    @Test func `guest info decodes os and addresses`() throws {
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
        #expect(guest.listeningPorts == nil)
    }

    @Test func `guest info decodes listening ports`() throws {
        let json = """
        {
          "available": true,
          "ipAddresses": ["192.168.64.12"],
          "listeningPorts": [
            {"proto":"tcp","address":"0.0.0.0","port":22,"scope":"network","label":"SSH"},
            {"proto":"tcp","address":"127.0.0.1","port":3000,"scope":"internal","label":"Dev"}
          ],
          "portsCollectedAt": "2026-08-18T00:00:00Z"
        }
        """.data(using: .utf8)!

        let guest = try decoder.decode(GuestInfo.self, from: json)
        #expect(guest.listeningPorts?.count == 2)
        #expect(guest.listeningPorts?.first?.label == "SSH")
        #expect(guest.listeningPorts?.last?.isInternal == true)
        #expect(guest.portsCollectedAt == "2026-08-18T00:00:00Z")
        #expect(guest.listeningPorts?.last?.displayLabel == "Dev")
        #expect(guest.listeningPorts?.first?.isPublished == true)
        #expect(guest.listeningPorts?.first?.openURL(guestIPs: ["192.168.64.12"]) == nil)
        let bridged = GuestListeningPortAccess(
            isMember: false, guestIpsReachable: true, portForwards: [],
        )
        let http = GuestListeningPort(
            proto: "tcp",
            address: "0.0.0.0",
            port: 80,
            scope: "network",
            label: "HTTP",
            scheme: "http",
            schemeKeyPresent: true,
        )
        #expect(http.openURL(guestIPs: ["192.168.64.12"], access: bridged)?.absoluteString == "http://192.168.64.12")
        #expect(http.isPublished)
        let rpc = GuestListeningPort(
            proto: "tcp", address: "0.0.0.0", port: 111, scope: "network",
            label: nil, scheme: nil, schemeKeyPresent: false,
        )
        #expect(!rpc.isPublished)

        let negative = GuestListeningPort(
            proto: "tcp", address: "0.0.0.0", port: 8_080, scope: "network",
            label: "HTTP", scheme: nil, schemeKeyPresent: true,
        )
        #expect(negative.openURL(guestIPs: ["192.168.64.12"], access: bridged) == nil)

        let natSelf = GuestListeningPortAccess(
            isMember: false,
            guestIpsReachable: false,
            portForwards: [GuestPortForward(proto: "tcp", hostPort: 8_080, guestPort: 80)],
        )
        #expect(http.openURL(guestIPs: ["10.0.2.15"], access: natSelf)?.absoluteString == "http://127.0.0.1:8080")
        let memberNAT = GuestListeningPortAccess(
            isMember: true,
            guestIpsReachable: false,
            portForwards: natSelf.portForwards,
        )
        #expect(http.openURL(guestIPs: ["10.0.2.15"], access: memberNAT) == nil)
    }

    @Test func `empty listening ports is none not unavailable`() throws {
        let json = """
        {
          "available": true,
          "ipAddresses": ["192.168.64.12"],
          "listeningPorts": []
        }
        """.data(using: .utf8)!
        let guest = try decoder.decode(GuestInfo.self, from: json)
        #expect(guest.listeningPorts?.isEmpty == true)
    }

    @Test func `guest info keeps nat fallback address when agent missing`() throws {
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

    @Test func `guest summary falls back to vm type family`() {
        let linux = fixtureWorkload(vmType: "linux-arm64")
        let windows = fixtureWorkload(id: "vm-win", name: "desktop", vmType: "windows-x86_64")
        #expect(WorkloadGuestSummary.osLabel(workload: linux, guest: nil) == "Linux")
        #expect(WorkloadGuestSummary.osLabel(workload: windows, guest: nil) == "Windows")
        #expect(WorkloadGuestSummary.ipLabel(guest: nil) == nil)

        let guest = GuestInfo(available: true, ipAddresses: [], osName: "Fedora", osVersion: nil)
        #expect(WorkloadGuestSummary.osLabel(workload: linux, guest: guest) == "Fedora")
    }

    @Test func `member console and display match this device when reachable`() {
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room", reachable: true)
        let down = snapshot(hostId: "down", role: "member", title: "Garage", reachable: false)
        #expect(WorkloadStreamAccess.resolve(device: living, state: "running") == .available)
        #expect(WorkloadStreamAccess.resolve(device: living, state: "running").allowsOpen)
        #expect(WorkloadStreamAccess.resolve(device: living, state: "stopped") == .notLive)
        #expect(WorkloadStreamAccess.resolve(device: down, state: "running") == .deviceUnreachable)
        #expect(!WorkloadStreamAccess.resolve(device: down, state: "running").allowsOpen)
    }

    @Test func `this device console opens only when live`() {
        #expect(WorkloadStream.isLive("running"))
        #expect(WorkloadStream.isLive("stopping"))
        #expect(!WorkloadStream.isLive("stopped"))
        #expect(!WorkloadStream.isLive("starting"))
        #expect(
            WorkloadStreamAccess.resolve(isSelfDevice: true, deviceReachable: true, state: "running")
                == .available,
        )
        #expect(
            WorkloadStreamAccess.resolve(isSelfDevice: true, deviceReachable: true, state: "stopping")
                == .available,
        )
        #expect(
            WorkloadStreamAccess.resolve(isSelfDevice: true, deviceReachable: true, state: "stopped")
                == .notLive,
        )
        #expect(
            !WorkloadStreamAccess.resolve(isSelfDevice: true, deviceReachable: true, state: "stopped")
                .allowsOpen,
        )
        #expect(WorkloadStreamAccess.notLive.reason == "The Workload must be running.")
    }

    @Test func `detail identity keeps device and workload together`() {
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

    @Test func `home list start and ACPI stop hide when unreachable or in flight`() {
        let stopped = fixtureWorkload(state: "stopped")
        let running = fixtureWorkload(state: "running")
        let starting = fixtureWorkload(state: "starting")
        let error = fixtureWorkload(state: "error")
        let stopping = fixtureWorkload(state: "stopping")

        #expect(
            WorkloadListActions.resolve(workload: stopped, deviceReachable: true, inFlight: false)
                == [.start],
        )
        #expect(
            WorkloadListActions.resolve(workload: error, deviceReachable: true, inFlight: false)
                == [.start],
        )
        #expect(
            WorkloadListActions.resolve(workload: running, deviceReachable: true, inFlight: false)
                == [.acpiStop],
        )
        #expect(
            WorkloadListActions.resolve(workload: starting, deviceReachable: true, inFlight: false)
                == [.acpiStop],
        )
        #expect(
            WorkloadListActions.resolve(workload: stopping, deviceReachable: true, inFlight: false)
                .isEmpty,
        )
        #expect(
            WorkloadListActions.resolve(workload: running, deviceReachable: false, inFlight: false)
                .isEmpty,
        )
        #expect(
            WorkloadListActions.resolve(workload: stopped, deviceReachable: false, inFlight: false)
                .isEmpty,
        )
        #expect(
            WorkloadListActions.resolve(workload: running, deviceReachable: true, inFlight: true)
                .isEmpty,
        )
        #expect(
            WorkloadListActions.resolve(workload: stopped, deviceReachable: true, inFlight: true)
                .isEmpty,
        )
        #expect(WorkloadListAction.acpiStop.title == "Stop")
        #expect(WorkloadListAction.start.title == "Start")
    }

    @Test func `start and ACPI stop use This Device or Home proxy paths`() throws {
        let client = try APIClient(baseURL: #require(URL(string: "http://192.168.30.1:7777")), token: "t")
        let selfDevice = snapshot(hostId: "self", role: "self", title: "Studio")
        let member = snapshot(hostId: "peer", role: "member", title: "Living Room")
        #expect(client.scoped("/vms/vm-1/start", on: selfDevice) == "/api/vms/vm-1/start")
        #expect(client.scoped("/vms/vm-1/stop", on: selfDevice) == "/api/vms/vm-1/stop")
        #expect(client.scoped("/vms/vm-1/start", on: nil) == "/api/vms/vm-1/start")
        #expect(
            client.scoped("/vms/vm-1/start", on: member)
                == "/api/home/devices/peer/v1/vms/vm-1/start",
        )
        #expect(
            client.scoped("/vms/vm-1/stop", on: member)
                == "/api/home/devices/peer/v1/vms/vm-1/stop",
        )
    }

    @Test func `ACPI stop body is not force`() throws {
        let encoder = JSONEncoder()
        let acpi = try JSONSerialization.jsonObject(
            with: encoder.encode(WorkloadStopBody(force: false, method: "acpi")),
        ) as? [String: Any]
        #expect(acpi?["force"] as? Bool == false)
        #expect(acpi?["method"] as? String == "acpi")
        let force = try JSONSerialization.jsonObject(
            with: encoder.encode(WorkloadStopBody(force: true, method: "force")),
        ) as? [String: Any]
        #expect(force?["force"] as? Bool == true)
        #expect(force?["method"] as? String == "force")
    }

    @Test func `action key matches home row and falls back to bare ID`() {
        let living = snapshot(hostId: "peer", role: "member", title: "Living Room")
        let haos = fixtureWorkload(id: "vm-1", name: "haos")
        #expect(WorkloadActionKey.id(hostID: "self", workloadID: "vm-1") == "self/vm-1")
        #expect(WorkloadActionKey.id(hostID: "peer", workloadID: "vm-1") == "peer/vm-1")
        #expect(WorkloadActionKey.id(hostID: nil, workloadID: "vm-1") == "vm-1")
        #expect(WorkloadActionKey.id(hostID: "", workloadID: "vm-1") == "vm-1")
        #expect(
            HomeWorkloadRow(workload: haos, device: living).id
                == WorkloadActionKey.id(hostID: "peer", workloadID: "vm-1"),
        )
    }

    @Test func `guest info stops retry after successful response`() {
        let missing = GuestInfo(available: false, ipAddresses: ["10.0.2.15"])
        let ready = GuestInfo(available: true, ipAddresses: ["192.168.64.12"], osName: "Ubuntu")
        #expect(GuestInfoRefresh.shouldRetry(guest: nil, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: missing, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: ready, running: true))
        #expect(!GuestInfoRefresh.shouldRetry(guest: nil, running: false))
        #expect(!GuestInfoRefresh.shouldRetry(guest: missing, running: false))
        #expect(!GuestInfoRefresh.shouldRetry(guest: nil, running: true, reachable: false))
        #expect(GuestInfoRefresh.pollIntervalSeconds(guest: nil, running: true) == 5)
        #expect(GuestInfoRefresh.pollIntervalSeconds(guest: ready, running: true) == 30)
        #expect(GuestInfoRefresh.pollIntervalSeconds(guest: ready, running: false) == nil)
        #expect(GuestInfoRefresh.pollIntervalSeconds(guest: ready, running: true, reachable: false) == nil)
        let live = GuestInfoRefresh.taskID(
            deviceID: "peer",
            workloadID: "vm-1",
            state: "running",
            reachable: true,
        )
        let down = GuestInfoRefresh.taskID(
            deviceID: "peer",
            workloadID: "vm-1",
            state: "running",
            reachable: false,
        )
        #expect(live != down)
        #expect(live.hasSuffix("/up"))
        #expect(down.hasSuffix("/down"))
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

    private func fixtureWorkload(
        id: String = "vm-1",
        name: String = "haos",
        vmType: String = "linux-arm64",
        state: String = "running",
    ) -> Workload {
        Workload(
            id: id,
            name: name,
            vmType: vmType,
            state: state,
            health: state == "running" ? "guest_ready" : nil,
            cpuCount: 2,
            memoryMB: 1_024,
            bootDiskId: "disk-1",
            isoId: nil,
            networkId: nil,
            description: nil,
            pendingChanges: nil,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
            status: nil,
            portForwards: nil,
        )
    }
}
