import BarkVisorHelperProtocol
import Foundation
import Testing

private enum XPCProxyError: Error {
    case castFailed
}

/// Wraps a non-Sendable value for use across concurrency boundaries in tests.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - HelperProtocol Constants Tests

struct HelperProtocolConstantsTests {
    @Test func `mach service name`() {
        #expect(kHelperMachServiceName == "dev.barkvisor.helper")
        #expect(!kHelperMachServiceName.isEmpty)
    }

    @Test func `team ID is defined`() {
        #expect(!kHelperTeamID.isEmpty)
        #expect(kHelperTeamID == "W363QN58YY")
    }
}

// MARK: - Interface Validation Tests

/// Tests the interface validation logic that mirrors HelperHandler.validateInterface.
/// We test the rules directly since HelperHandler is in a separate module without
/// public visibility for its private helpers.
struct InterfaceValidationTests {
    /// Mirrors HelperHandler.validateInterface for testing purposes.
    private func validateInterface(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 15
            && name.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Valid interfaces

    @Test func `valid simple interface`() {
        #expect(validateInterface("en0"))
    }

    @Test func `valid longer interface`() {
        #expect(validateInterface("bridge0"))
    }

    @Test func `valid all letters`() {
        #expect(validateInterface("loopback"))
    }

    @Test func `valid all digits`() {
        #expect(validateInterface("12345"))
    }

    @Test func `valid max length`() {
        let name = String(repeating: "a", count: 15)
        #expect(validateInterface(name))
    }

    // MARK: Invalid interfaces

    @Test func `empty interface`() {
        #expect(!validateInterface(""))
    }

    @Test func `interface too long`() {
        let name = String(repeating: "a", count: 16)
        #expect(!validateInterface(name))
    }

    @Test func `interface with dot`() {
        #expect(!validateInterface("en0.1"))
    }

    @Test func `interface with space`() {
        #expect(!validateInterface("en 0"))
    }

    @Test func `interface with slash`() {
        #expect(!validateInterface("en0/1"))
    }

    @Test func `interface with semicolon`() {
        #expect(!validateInterface("en0;rm"))
    }

    @Test func `interface with dash`() {
        #expect(!validateInterface("en-0"))
    }

    @Test func `interface with underscore`() {
        #expect(!validateInterface("en_0"))
    }

    @Test func `interface with path traversal`() {
        #expect(!validateInterface("../etc"))
    }

    @Test func `interface with shell injection`() {
        #expect(!validateInterface("en0; rm -rf /"))
    }

    @Test func `interface with newline`() {
        #expect(!validateInterface("en0\n"))
    }

    @Test func `interface with null`() {
        #expect(!validateInterface("en0\0"))
    }

    @Test func `interface with unicode`() {
        // Unicode letters should be accepted by Character.isLetter
        #expect(validateInterface("ën0"))
    }
}

// MARK: - Vmnet Path Validation Tests

/// Tests the vmnet binary path validation logic mirroring HelperHandler.validateVmnetPath.
struct VmnetPathValidationTests {
    /// Mirrors HelperHandler.validateVmnetPath for testing purposes.
    private func validateVmnetPath(_ path: String) -> Bool {
        let canonicalized = (path as NSString).resolvingSymlinksInPath
        let allowed = ["/opt/homebrew/", "/usr/local/", "/opt/socket_vmnet/"]
        return allowed.contains { canonicalized.hasPrefix($0) }
    }

    @Test func `valid homebrew path`() {
        #expect(validateVmnetPath("/opt/homebrew/bin/socket_vmnet"))
    }

    @Test func `valid usr local path`() {
        #expect(validateVmnetPath("/usr/local/bin/socket_vmnet"))
    }

    @Test func `valid opt socket vmnet path`() {
        #expect(validateVmnetPath("/opt/socket_vmnet/bin/socket_vmnet"))
    }

    @Test func `invalid root path`() {
        #expect(!validateVmnetPath("/bin/socket_vmnet"))
    }

    @Test func `invalid usr bin path`() {
        #expect(!validateVmnetPath("/usr/bin/socket_vmnet"))
    }

    @Test func `invalid etc path`() {
        #expect(!validateVmnetPath("/etc/socket_vmnet"))
    }

    @Test func `invalid tmp path`() {
        #expect(!validateVmnetPath("/tmp/socket_vmnet"))
    }

    @Test func `empty path`() {
        #expect(!validateVmnetPath(""))
    }

    @Test func `relative path`() {
        // Relative paths resolve against cwd, which won't match allowed prefixes
        #expect(!validateVmnetPath("socket_vmnet"))
    }

    @Test func `path with trailing slash only`() {
        #expect(!validateVmnetPath("/"))
    }

    @Test func `path prefix partial match`() {
        // "/opt/homebrewfake" should NOT match "/opt/homebrew/"
        #expect(!validateVmnetPath("/opt/homebrewfake/bin/socket_vmnet"))
    }
}

// MARK: - Extended XPC Round-trip Tests

/// Extended tests for XPC protocol methods beyond what HelperXPCTests covers.
/// Uses an anonymous XPC listener to test all protocol methods in-process.
final class HelperXPCExtendedTests {
    /// Test handler that validates inputs like the real HelperHandler.
    private class StrictTestHandler: NSObject, HelperProtocol {
        func getVersion(reply: @escaping (String) -> Void) {
            reply("1.0.0")
        }

        func ping(reply: @escaping (String) -> Void) {
            reply("Hello from BarkVisorHelper!")
        }

        private func validateInterface(_ name: String) -> Bool {
            !name.isEmpty
                && name.count <= 15
                && name.allSatisfy { $0.isLetter || $0.isNumber }
        }

        func installBridge(
            interface: String,
            reply: @escaping (Bool, String?) -> Void,
        ) {
            guard validateInterface(interface) else {
                reply(false, "Invalid interface name: must be alphanumeric, max 15 chars")
                return
            }
            reply(true, nil)
        }

        func removeBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
            guard validateInterface(interface) else {
                reply(false, "Invalid interface name")
                return
            }
            reply(true, nil)
        }

        func startBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
            guard validateInterface(interface) else {
                reply(false, "Invalid interface name")
                return
            }
            reply(true, nil)
        }

        func stopBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
            guard validateInterface(interface) else {
                reply(false, "Invalid interface name")
                return
            }
            reply(true, nil)
        }

        func bridgeStatus(interface: String, reply: @escaping (Bool, String?) -> Void) {
            guard validateInterface(interface) else {
                reply(false, "Invalid interface name")
                return
            }
            reply(false, "not_installed")
        }

        func getAllBridgeStates(reply: @escaping (String) -> Void) {
            reply("[]")
        }

        func installUpdate(
            packagePath: String,
            expectedVersion: String,
            reply: @escaping (Bool, String?) -> Void,
        ) {
            reply(false, "Not supported in test")
        }
    }

    private class StrictListenerDelegate: NSObject, NSXPCListenerDelegate {
        func listener(
            _ listener: NSXPCListener,
            shouldAcceptNewConnection connection: NSXPCConnection,
        ) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
            connection.exportedObject = StrictTestHandler()
            connection.resume()
            return true
        }
    }

    private let listener: NSXPCListener
    private let listenerDelegate: StrictListenerDelegate
    private let connection: NSXPCConnection

    init() {
        listenerDelegate = StrictListenerDelegate()
        let newListener = NSXPCListener.anonymous()
        newListener.delegate = listenerDelegate
        newListener.resume()
        listener = newListener

        let conn = NSXPCConnection(listenerEndpoint: newListener.endpoint)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.resume()
        connection = conn
    }

    deinit {
        connection.invalidate()
        listener.invalidate()
    }

    private func proxy() -> HelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            Issue.record("XPC error: \(error)")
        } as? HelperProtocol
    }

    // MARK: - startBridge

    @Test func `start bridge valid`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func `start bridge invalid interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0;bad") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
        #expect(result.1 != nil)
    }

    @Test func `start bridge empty interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
    }

    // MARK: - stopBridge

    @Test func `stop bridge valid`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func `stop bridge invalid interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
    }

    // MARK: - bridgeStatus

    @Test func `bridge status valid`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "en0") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        #expect(!result.0)
        #expect(result.1 == "not_installed")
    }

    @Test func `bridge status invalid interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "../etc") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        #expect(!result.0)
        #expect(result.1?.contains("Invalid") ?? false)
    }

    // MARK: - getAllBridgeStates

    @Test func `get all bridge states returns JSON`() async throws {
        let p = try #require(proxy())
        let json: String = try await withCheckedThrowingContinuation { cont in
            p.getAllBridgeStates { reply in
                cont.resume(returning: reply)
            }
        }
        #expect(json == "[]")
        // Verify it parses as valid JSON array
        let data = try #require(json.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(parsed != nil)
    }

    // MARK: - removeBridge

    @Test func `remove bridge invalid interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: "en0/../../etc") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
        #expect(result.1 != nil)
    }

    @Test func `remove bridge interface too long`() async throws {
        let longName = String(repeating: "a", count: 16)
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: longName) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
    }

    // MARK: - Concurrent XPC calls

    @Test func `concurrent pings`() async throws {
        let conn = UnsafeSendable(connection)
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0 ..< 10 {
                group.addTask {
                    try await withCheckedThrowingContinuation { cont in
                        guard let p =
                            conn.value.remoteObjectProxyWithErrorHandler({ error in
                                cont.resume(throwing: error)
                            }) as? HelperProtocol
                        else {
                            cont.resume(throwing: XPCProxyError.castFailed)
                            return
                        }
                        p.ping { reply in
                            cont.resume(returning: reply)
                        }
                    }
                }
            }
            var count = 0
            for try await reply in group {
                #expect(reply == "Hello from BarkVisorHelper!")
                count += 1
            }
            #expect(count == 10)
        }
    }
}
