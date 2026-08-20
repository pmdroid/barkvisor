import Foundation
import Testing
@testable import BarkVisorCore

struct StreamTicketPolicyTests {
    private static let ticket = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    @Test func `home tunnel is pass-through not owner spend`() {
        let homeVNC = "/api/home/devices/peer-1/v1/vms/vm-1/vnc"
        let homeConsole = "/api/home/devices/peer-1/v1/vms/vm-1/console"
        let localVNC = "/api/vms/vm-1/vnc"
        let localConsole = "/api/vms/vm-1/console"
        let logs = "/api/logs/stream"

        #expect(StreamTicketPolicy.site(path: homeVNC) == .homeTunnel)
        #expect(StreamTicketPolicy.site(path: homeConsole) == .homeTunnel)
        #expect(StreamTicketPolicy.site(path: localVNC) == .ownerDevice)
        #expect(StreamTicketPolicy.site(path: localConsole) == .ownerDevice)
        #expect(StreamTicketPolicy.site(path: logs) == .other)
        #expect(StreamTicketPolicy.isHomeConsoleTunnel(homeVNC))
        #expect(!StreamTicketPolicy.isHomeConsoleTunnel(localVNC))
        #expect(!StreamTicketPolicy.isHomeConsoleTunnel("/api/home/devices/peer-1/v1/vms/vm-1/start"))
    }

    @Test func `device ticket accepts noVNC token rewrite`() {
        #expect(
            StreamTicketPolicy.deviceTicket(fromQuery: "ticket=\(Self.ticket)") == Self.ticket,
        )
        #expect(
            StreamTicketPolicy.deviceTicket(fromQuery: "token=\(Self.ticket)&session=home")
                == Self.ticket,
        )
        #expect(
            StreamTicketPolicy.deviceTicket(fromQuery: "ticket=device&token=novnc") == "device",
        )
        #expect(StreamTicketPolicy.homeSession(fromQuery: "ticket=a&session=home") == "home")
        #expect(StreamTicketPolicy.homeSession(fromQuery: "ticket=a") == nil)
        #expect(StreamTicketPolicy.deviceTicket(fromQuery: nil) == nil)
        #expect(StreamTicketPolicy.deviceTicket(fromQuery: "session=only") == nil)
    }

    @Test func `home pass-through checks uuid shape and does not spend`() async throws {
        try StreamTicketPolicy.requirePassThroughDeviceTicket(Self.ticket)
        #expect(throws: BarkVisorError.self) {
            try StreamTicketPolicy.requirePassThroughDeviceTicket(nil)
        }
        #expect(throws: BarkVisorError.self) {
            try StreamTicketPolicy.requirePassThroughDeviceTicket("")
        }
        #expect(throws: BarkVisorError.self) {
            try StreamTicketPolicy.requirePassThroughDeviceTicket("not-a-uuid")
        }

        let store = WebSocketTicketStore.shared
        let minted = await store.createTicket(
            forUserID: "u1", username: "admin", targetVMID: "vm-1",
        )
        try StreamTicketPolicy.requirePassThroughDeviceTicket(minted)
        let spent = await store.validateTicket(minted, forVMID: "vm-1")
        #expect(spent?.userID == "u1", "Home pass-through must not consume the Device ticket")
        let second = await store.validateTicket(minted, forVMID: "vm-1")
        #expect(second == nil, "Owner Device spend is still one-use")
    }

    @Test func `hop query keeps device ticket and drops home session`() {
        #expect(
            StreamTicketPolicy.hopQuery(from: "ticket=abc&session=home&token=novnc") == "ticket=abc",
        )
        #expect(
            StreamTicketPolicy.hopQuery(from: "token=device-ticket&session=home")
                == "ticket=device-ticket",
        )
        #expect(StreamTicketPolicy.hopQuery(from: "session=home") == nil)
        #expect(StreamTicketPolicy.hopQuery(from: nil) == nil)
    }

    @Test func `client query keeps ticket and session contract`() {
        #expect(StreamTicketPolicy.clientQuery(ticket: "t1", session: nil) == "ticket=t1")
        #expect(StreamTicketPolicy.clientQuery(ticket: "t1", session: "") == "ticket=t1")
        let both = StreamTicketPolicy.clientQuery(ticket: "device", session: "home")
        #expect(both.contains("ticket=device"))
        #expect(both.contains("session=home"))
        #expect(!both.contains("token="))
        #expect(StreamTicketPolicy.needsHomeSession(isSelfDevice: false))
        #expect(!StreamTicketPolicy.needsHomeSession(isSelfDevice: true))
        #expect(StreamTicketPolicy.mintBody(workloadID: "vm-9") == ["vmID": "vm-9"])
    }

    @Test func `owner device spend is workload scoped`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(
            forUserID: "u1", username: "admin", targetVMID: "vm-1",
        )
        #expect(await store.validateTicket(ticket, forVMID: "vm-2") == nil)
        let other = await store.createTicket(
            forUserID: "u1", username: "admin", targetVMID: "vm-1",
        )
        #expect(await store.validateTicket(other, forVMID: "vm-1") != nil)
    }
}
