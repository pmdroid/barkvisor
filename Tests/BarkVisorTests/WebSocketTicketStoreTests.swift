import Foundation
import Testing
@testable import BarkVisorCore

struct WebSocketTicketStoreTests {
    @Test func `create and validate VM ticket`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        #expect(!ticket.isEmpty)

        let result = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(result != nil)
        #expect(result?.userID == "u1")
        #expect(result?.username == "admin")
    }

    @Test func `ticket is single use`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let first = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(first != nil)

        // Second use should fail
        let second = await store.validateTicket(ticket, forVMID: "vm-1")
        #expect(second == nil, "Ticket should be consumed after first use")
    }

    @Test func `ticket wrong VM`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let result = await store.validateTicket(ticket, forVMID: "vm-2")
        #expect(result == nil, "Ticket scoped to vm-1 should not validate for vm-2")
        #expect(await store.validateTicket(ticket, forVMID: "vm-1") == nil)
    }

    @Test func `non scoped ticket`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let result = await store.validateTicket(ticket)
        #expect(result != nil)
        #expect(result?.userID == "u1")
    }

    @Test func `non scoped ticket is single use`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let first = await store.validateTicket(ticket)
        #expect(first != nil)

        let second = await store.validateTicket(ticket)
        #expect(second == nil)
    }

    @Test func `unscoped SSE rejects a Workload scoped ticket`() async {
        let store = TicketTestClock().makeStore()
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let unscoped = await store.validateTicket(ticket)
        #expect(unscoped == nil, "VM-scoped tickets must not authenticate logs/progress SSE")
        #expect(await store.validateTicket(ticket, forVMID: "vm-1") == nil)
    }

    @Test func `invalid ticket returns nil`() async {
        let store = TicketTestClock().makeStore()
        let result = await store.validateTicket("nonexistent-ticket", forVMID: "vm-1")
        #expect(result == nil)

        let result2 = await store.validateTicket("nonexistent-ticket")
        #expect(result2 == nil)
    }

    @Test(arguments: [29.0, 30.0, 31.0], [false, true])
    func `tickets expire exactly thirty seconds after creation`(
        elapsed: TimeInterval,
        scoped: Bool,
    ) async {
        let clock = TicketTestClock()
        let store = clock.makeStore()
        let ticket = await store.createTicket(
            forUserID: "u1", username: "admin", targetVMID: scoped ? "vm-1" : nil,
        )
        clock.advance(by: elapsed)

        let result = if scoped {
            await store.validateTicket(ticket, forVMID: "vm-1")
        } else {
            await store.validateTicket(ticket)
        }
        #expect((result != nil) == (elapsed < 30))

        // Rewinding the clock cannot revive a consumed or expired ticket.
        clock.advance(by: -elapsed)
        let replay = if scoped {
            await store.validateTicket(ticket, forVMID: "vm-1")
        } else {
            await store.validateTicket(ticket)
        }
        #expect(replay == nil)
    }
}
