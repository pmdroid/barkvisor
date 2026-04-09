import XCTest

/// Tests BridgeState encoding/decoding. BridgeState is defined in BridgeMonitor.swift
/// which is in the BarkVisorHelper target. Since we can't import it directly, we
/// replicate the struct to test the Codable contract.
final class BridgeStateCodableTests: XCTestCase {
    /// Mirror of BridgeState from BridgeMonitor.swift for Codable testing.
    private struct BridgeState: Codable, Equatable {
        let interface: String
        let socketPath: String?
        let plistExists: Bool
        let daemonRunning: Bool
        let status: String
    }

    func testRoundTrip() throws {
        let state = BridgeState(
            interface: "en0",
            socketPath: "/var/run/socket_vmnet.bridged.en0",
            plistExists: true,
            daemonRunning: true,
            status: "active",
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
        XCTAssertEqual(state, decoded)
    }

    func testNilSocketPath() throws {
        let state = BridgeState(
            interface: "en1",
            socketPath: nil,
            plistExists: false,
            daemonRunning: false,
            status: "not_configured",
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
        XCTAssertEqual(decoded.socketPath, nil)
        XCTAssertEqual(decoded.status, "not_configured")
    }

    func testArrayEncoding() throws {
        let states = [
            BridgeState(
                interface: "en0", socketPath: nil, plistExists: true, daemonRunning: false,
                status: "installed",
            ),
            BridgeState(
                interface: "en1", socketPath: "/var/run/socket_vmnet.bridged.en1", plistExists: true,
                daemonRunning: true, status: "active",
            ),
        ]
        let data = try JSONEncoder().encode(states)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("en0"))
        XCTAssertTrue(json.contains("en1"))

        let decoded = try JSONDecoder().decode([BridgeState].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].interface, "en0")
        XCTAssertEqual(decoded[1].interface, "en1")
    }

    func testEmptyArrayEncoding() throws {
        let states: [BridgeState] = []
        let data = try JSONEncoder().encode(states)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json, "[]")
    }

    func testDecodeFromExternalJSON() throws {
        let json = """
        {"interface":"bridge0","socketPath":"/var/run/socket_vmnet.bridged.bridge0","plistExists":true,"daemonRunning":true,"status":"active"}
        """
        let state = try JSONDecoder().decode(BridgeState.self, from: XCTUnwrap(json.data(using: .utf8)))
        XCTAssertEqual(state.interface, "bridge0")
        XCTAssertEqual(state.socketPath, "/var/run/socket_vmnet.bridged.bridge0")
        XCTAssertTrue(state.plistExists)
        XCTAssertTrue(state.daemonRunning)
        XCTAssertEqual(state.status, "active")
    }

    func testStatusValues() throws {
        for status in ["active", "installed", "not_configured"] {
            let state = BridgeState(
                interface: "en0", socketPath: nil,
                plistExists: false, daemonRunning: false, status: status,
            )
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
            XCTAssertEqual(decoded.status, status)
        }
    }
}
