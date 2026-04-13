import Foundation
import Testing
@testable import BarkVisorCore

struct WebSocketTicketStoreTests {
    // We use the shared singleton — tests are serial within this suite

    @Test func `create and validate VM ticket`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        #expect(!ticket.isEmpty)

        let result = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(result != nil)
        #expect(result?.userID == "u1")
        #expect(result?.username == "admin")
    }

    @Test func `ticket is single use`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let first = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(first != nil)

        // Second use should fail
        let second = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(second == nil, "Ticket should be consumed after first use")
    }

    @Test func `ticket wrong VM`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let result = await store.validateTicket(ticket, forVMID: "vm-2")
        #expect(result == nil, "Ticket scoped to vm-1 should not validate for vm-2")
    }

    @Test func `non scoped ticket`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let result = await store.validateTicket(ticket)
        #expect(result != nil)
        #expect(result?.userID == "u1")
    }

    @Test func `non scoped ticket is single use`() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let first = await store.validateTicket(ticket)
        #expect(first != nil)

        let second = await store.validateTicket(ticket)
        #expect(second == nil)
    }

    @Test func `invalid ticket returns nil`() async {
        let store = WebSocketTicketStore.shared
        let result = await store.validateTicket("nonexistent-ticket", forVMID: "vm-1")
        #expect(result == nil)

        let result2 = await store.validateTicket("nonexistent-ticket")
        #expect(result2 == nil)
    }
}
