import BarkVisorHelperProtocol
import XCTest

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

final class HelperProtocolConstantsTests: XCTestCase {
    func testMachServiceName() {
        XCTAssertEqual(kHelperMachServiceName, "dev.barkvisor.helper")
        XCTAssertFalse(kHelperMachServiceName.isEmpty)
    }

    func testTeamIDIsDefined() {
        XCTAssertFalse(kHelperTeamID.isEmpty)
        XCTAssertEqual(kHelperTeamID, "W363QN58YY")
    }
}

// MARK: - Interface Validation Tests

/// Tests the interface validation logic that mirrors HelperHandler.validateInterface.
/// We test the rules directly since HelperHandler is in a separate module without
/// public visibility for its private helpers.
final class InterfaceValidationTests: XCTestCase {
    /// Mirrors HelperHandler.validateInterface for testing purposes.
    private func validateInterface(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 15
            && name.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Valid interfaces

    func testValidSimpleInterface() {
        XCTAssertTrue(validateInterface("en0"))
    }

    func testValidLongerInterface() {
        XCTAssertTrue(validateInterface("bridge0"))
    }

    func testValidAllLetters() {
        XCTAssertTrue(validateInterface("loopback"))
    }

    func testValidAllDigits() {
        XCTAssertTrue(validateInterface("12345"))
    }

    func testValidMaxLength() {
        let name = String(repeating: "a", count: 15)
        XCTAssertTrue(validateInterface(name))
    }

    // MARK: Invalid interfaces

    func testEmptyInterface() {
        XCTAssertFalse(validateInterface(""))
    }

    func testInterfaceTooLong() {
        let name = String(repeating: "a", count: 16)
        XCTAssertFalse(validateInterface(name))
    }

    func testInterfaceWithDot() {
        XCTAssertFalse(validateInterface("en0.1"))
    }

    func testInterfaceWithSpace() {
        XCTAssertFalse(validateInterface("en 0"))
    }

    func testInterfaceWithSlash() {
        XCTAssertFalse(validateInterface("en0/1"))
    }

    func testInterfaceWithSemicolon() {
        XCTAssertFalse(validateInterface("en0;rm"))
    }

    func testInterfaceWithDash() {
        XCTAssertFalse(validateInterface("en-0"))
    }

    func testInterfaceWithUnderscore() {
        XCTAssertFalse(validateInterface("en_0"))
    }

    func testInterfaceWithPathTraversal() {
        XCTAssertFalse(validateInterface("../etc"))
    }

    func testInterfaceWithShellInjection() {
        XCTAssertFalse(validateInterface("en0; rm -rf /"))
    }

    func testInterfaceWithNewline() {
        XCTAssertFalse(validateInterface("en0\n"))
    }

    func testInterfaceWithNull() {
        XCTAssertFalse(validateInterface("en0\0"))
    }

    func testInterfaceWithUnicode() {
        // Unicode letters should be accepted by Character.isLetter
        XCTAssertTrue(validateInterface("ën0"))
    }
}

// MARK: - Vmnet Path Validation Tests

/// Tests the vmnet binary path validation logic mirroring HelperHandler.validateVmnetPath.
final class VmnetPathValidationTests: XCTestCase {
    /// Mirrors HelperHandler.validateVmnetPath for testing purposes.
    private func validateVmnetPath(_ path: String) -> Bool {
        let canonicalized = (path as NSString).resolvingSymlinksInPath
        let allowed = ["/opt/homebrew/", "/usr/local/", "/opt/socket_vmnet/"]
        return allowed.contains { canonicalized.hasPrefix($0) }
    }

    func testValidHomebrewPath() {
        XCTAssertTrue(validateVmnetPath("/opt/homebrew/bin/socket_vmnet"))
    }

    func testValidUsrLocalPath() {
        XCTAssertTrue(validateVmnetPath("/usr/local/bin/socket_vmnet"))
    }

    func testValidOptSocketVmnetPath() {
        XCTAssertTrue(validateVmnetPath("/opt/socket_vmnet/bin/socket_vmnet"))
    }

    func testInvalidRootPath() {
        XCTAssertFalse(validateVmnetPath("/bin/socket_vmnet"))
    }

    func testInvalidUsrBinPath() {
        XCTAssertFalse(validateVmnetPath("/usr/bin/socket_vmnet"))
    }

    func testInvalidEtcPath() {
        XCTAssertFalse(validateVmnetPath("/etc/socket_vmnet"))
    }

    func testInvalidTmpPath() {
        XCTAssertFalse(validateVmnetPath("/tmp/socket_vmnet"))
    }

    func testEmptyPath() {
        XCTAssertFalse(validateVmnetPath(""))
    }

    func testRelativePath() {
        // Relative paths resolve against cwd, which won't match allowed prefixes
        XCTAssertFalse(validateVmnetPath("socket_vmnet"))
    }

    func testPathWithTrailingSlashOnly() {
        XCTAssertFalse(validateVmnetPath("/"))
    }

    func testPathPrefixPartialMatch() {
        // "/opt/homebrewfake" should NOT match "/opt/homebrew/"
        XCTAssertFalse(validateVmnetPath("/opt/homebrewfake/bin/socket_vmnet"))
    }
}

// MARK: - Extended XPC Round-trip Tests

/// Extended tests for XPC protocol methods beyond what HelperXPCTests covers.
/// Uses an anonymous XPC listener to test all protocol methods in-process.
final class HelperXPCExtendedTests: XCTestCase {
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

    private var listener: NSXPCListener?
    private var listenerDelegate: StrictListenerDelegate?
    private var connection: NSXPCConnection?

    override func setUp() {
        super.setUp()
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

    override func tearDown() {
        connection?.invalidate()
        listener?.invalidate()
        super.tearDown()
    }

    private func proxy() throws -> HelperProtocol {
        let conn = try XCTUnwrap(connection)
        return try XCTUnwrap(
            conn.remoteObjectProxyWithErrorHandler { error in
                XCTFail("XPC error: \(error)")
            } as? HelperProtocol,
        )
    }

    // MARK: - startBridge

    func testStartBridgeValid() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
    }

    func testStartBridgeInvalidInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0;bad") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertNotNil(result.1)
    }

    func testStartBridgeEmptyInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
    }

    // MARK: - stopBridge

    func testStopBridgeValid() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
    }

    func testStopBridgeInvalidInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
    }

    // MARK: - bridgeStatus

    func testBridgeStatusValid() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "en0") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "not_installed")
    }

    func testBridgeStatusInvalidInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "../etc") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertTrue(result.1?.contains("Invalid") ?? false)
    }

    // MARK: - getAllBridgeStates

    func testGetAllBridgeStatesReturnsJSON() async throws {
        let p = try proxy()
        let json: String = try await withCheckedThrowingContinuation { cont in
            p.getAllBridgeStates { reply in
                cont.resume(returning: reply)
            }
        }
        XCTAssertEqual(json, "[]")
        // Verify it parses as valid JSON array
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [Any]
        XCTAssertNotNil(parsed)
    }

    // MARK: - removeBridge

    func testRemoveBridgeInvalidInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: "en0/../../etc") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertNotNil(result.1)
    }

    func testRemoveBridgeInterfaceTooLong() async throws {
        let longName = String(repeating: "a", count: 16)
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: longName) { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
    }

    // MARK: - Concurrent XPC calls

    func testConcurrentPings() async throws {
        let conn = try UnsafeSendable(XCTUnwrap(connection))
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
                XCTAssertEqual(reply, "Hello from BarkVisorHelper!")
                count += 1
            }
            XCTAssertEqual(count, 10)
        }
    }
}
