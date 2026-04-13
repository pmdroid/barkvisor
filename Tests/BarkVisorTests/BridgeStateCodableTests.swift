import Foundation
import Testing

/// Tests BridgeState encoding/decoding. BridgeState is defined in BridgeMonitor.swift
/// which is in the BarkVisorHelper target. Since we can't import it directly, we
/// replicate the struct to test the Codable contract.
struct BridgeStateCodableTests {
    /// Mirror of BridgeState from BridgeMonitor.swift for Codable testing.
    private struct BridgeState: Codable, Equatable {
        let interface: String
        let socketPath: String?
        let plistExists: Bool
        let daemonRunning: Bool
        let status: String
    }

    @Test func `round trip`() throws {
        let state = BridgeState(
            interface: "en0", socketPath: "/var/run/socket_vmnet.bridged.en0",
            plistExists: true, daemonRunning: true, status: "active",
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
        #expect(state == decoded)
    }

    @Test func `nil socket path`() throws {
        let state = BridgeState(
            interface: "en1", socketPath: nil, plistExists: false, daemonRunning: false,
            status: "not_configured",
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
        #expect(decoded.socketPath == nil)
        #expect(decoded.status == "not_configured")
    }

    @Test func `array encoding`() throws {
        let states = [
            BridgeState(interface: "en0", socketPath: nil, plistExists: true, daemonRunning: false, status: "installed"),
            BridgeState(
                interface: "en1", socketPath: "/var/run/socket_vmnet.bridged.en1",
                plistExists: true, daemonRunning: true, status: "active",
            ),
        ]
        let data = try JSONEncoder().encode(states)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("en0"))
        #expect(json.contains("en1"))

        let decoded = try JSONDecoder().decode([BridgeState].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].interface == "en0")
        #expect(decoded[1].interface == "en1")
    }

    @Test func `empty array encoding`() throws {
        let states: [BridgeState] = []
        let data = try JSONEncoder().encode(states)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == "[]")
    }

    @Test func `decode from external JSON`() throws {
        let json = """
        {"interface":"bridge0","socketPath":"/var/run/socket_vmnet.bridged.bridge0","plistExists":true,"daemonRunning":true,"status":"active"}
        """
        let state = try JSONDecoder().decode(BridgeState.self, from: #require(json.data(using: .utf8)))
        #expect(state.interface == "bridge0")
        #expect(state.socketPath == "/var/run/socket_vmnet.bridged.bridge0")
        #expect(state.plistExists)
        #expect(state.daemonRunning)
        #expect(state.status == "active")
    }

    @Test func `status values`() throws {
        for status in ["active", "installed", "not_configured"] {
            let state = BridgeState(
                interface: "en0", socketPath: nil, plistExists: false, daemonRunning: false, status: status,
            )
            let data = try JSONEncoder().encode(state)
            let decoded = try JSONDecoder().decode(BridgeState.self, from: data)
            #expect(decoded.status == status)
        }
    }
}
