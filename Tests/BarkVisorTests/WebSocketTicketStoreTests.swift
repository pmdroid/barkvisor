import XCTest
@testable import BarkVisorCore

final class WebSocketTicketStoreTests: XCTestCase {
    // We use the shared singleton — tests are serial within this class

    func testCreateAndValidateVMTicket() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        XCTAssertFalse(ticket.isEmpty)

        let result = await store.validateTicket(ticket, forVMID: "vm-1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userID, "u1")
        XCTAssertEqual(result?.username, "admin")
    }

    func testTicketIsSingleUse() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let first = await store.validateTicket(ticket, forVMID: "vm-1")
        XCTAssertNotNil(first)

        // Second use should fail
        let second = await store.validateTicket(ticket, forVMID: "vm-1")
        XCTAssertNil(second, "Ticket should be consumed after first use")
    }

    func testTicketWrongVM() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin", targetVMID: "vm-1")

        let result = await store.validateTicket(ticket, forVMID: "vm-2")
        XCTAssertNil(result, "Ticket scoped to vm-1 should not validate for vm-2")
    }

    func testNonScopedTicket() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let result = await store.validateTicket(ticket)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.userID, "u1")
    }

    func testNonScopedTicketIsSingleUse() async {
        let store = WebSocketTicketStore.shared
        let ticket = await store.createTicket(forUserID: "u1", username: "admin")

        let first = await store.validateTicket(ticket)
        XCTAssertNotNil(first)

        let second = await store.validateTicket(ticket)
        XCTAssertNil(second)
    }

    func testInvalidTicketReturnsNil() async {
        let store = WebSocketTicketStore.shared
        let result = await store.validateTicket("nonexistent-ticket", forVMID: "vm-1")
        XCTAssertNil(result)

        let result2 = await store.validateTicket("nonexistent-ticket")
        XCTAssertNil(result2)
    }
}
