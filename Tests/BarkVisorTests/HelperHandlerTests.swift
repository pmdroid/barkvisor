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

@Suite struct HelperProtocolConstantsTests {
    @Test func machServiceName() {
        #expect(kHelperMachServiceName == "dev.barkvisor.helper")
        #expect(!kHelperMachServiceName.isEmpty)
    }

    @Test func teamIDIsDefined() {
        #expect(!kHelperTeamID.isEmpty)
        #expect(kHelperTeamID == "W363QN58YY")
    }
}

// MARK: - Interface Validation Tests

/// Tests the interface validation logic that mirrors HelperHandler.validateInterface.
/// We test the rules directly since HelperHandler is in a separate module without
/// public visibility for its private helpers.
@Suite struct InterfaceValidationTests {
    /// Mirrors HelperHandler.validateInterface for testing purposes.
    private func validateInterface(_ name: String) -> Bool {
        !name.isEmpty
            && name.count <= 15
            && name.allSatisfy { $0.isLetter || $0.isNumber }
    }

    // MARK: Valid interfaces

    @Test func validSimpleInterface() {
        #expect(validateInterface("en0"))
    }

    @Test func validLongerInterface() {
        #expect(validateInterface("bridge0"))
    }

    @Test func validAllLetters() {
        #expect(validateInterface("loopback"))
    }

    @Test func validAllDigits() {
        #expect(validateInterface("12345"))
    }

    @Test func validMaxLength() {
        let name = String(repeating: "a", count: 15)
        #expect(validateInterface(name))
    }

    // MARK: Invalid interfaces

    @Test func emptyInterface() {
        #expect(!validateInterface(""))
    }

    @Test func interfaceTooLong() {
        let name = String(repeating: "a", count: 16)
        #expect(!validateInterface(name))
    }

    @Test func interfaceWithDot() {
        #expect(!validateInterface("en0.1"))
    }

    @Test func interfaceWithSpace() {
        #expect(!validateInterface("en 0"))
    }

    @Test func interfaceWithSlash() {
        #expect(!validateInterface("en0/1"))
    }

    @Test func interfaceWithSemicolon() {
        #expect(!validateInterface("en0;rm"))
    }

    @Test func interfaceWithDash() {
        #expect(!validateInterface("en-0"))
    }

    @Test func interfaceWithUnderscore() {
        #expect(!validateInterface("en_0"))
    }

    @Test func interfaceWithPathTraversal() {
        #expect(!validateInterface("../etc"))
    }

    @Test func interfaceWithShellInjection() {
        #expect(!validateInterface("en0; rm -rf /"))
    }

    @Test func interfaceWithNewline() {
        #expect(!validateInterface("en0\n"))
    }

    @Test func interfaceWithNull() {
        #expect(!validateInterface("en0\0"))
    }

    @Test func interfaceWithUnicode() {
        // Unicode letters should be accepted by Character.isLetter
        #expect(validateInterface("ën0"))
    }
}

// MARK: - Vmnet Path Validation Tests

/// Tests the vmnet binary path validation logic mirroring HelperHandler.validateVmnetPath.
@Suite struct VmnetPathValidationTests {
    /// Mirrors HelperHandler.validateVmnetPath for testing purposes.
    private func validateVmnetPath(_ path: String) -> Bool {
        let canonicalized = (path as NSString).resolvingSymlinksInPath
        let allowed = ["/opt/homebrew/", "/usr/local/", "/opt/socket_vmnet/"]
        return allowed.contains { canonicalized.hasPrefix($0) }
    }

    @Test func validHomebrewPath() {
        #expect(validateVmnetPath("/opt/homebrew/bin/socket_vmnet"))
    }

    @Test func validUsrLocalPath() {
        #expect(validateVmnetPath("/usr/local/bin/socket_vmnet"))
    }

    @Test func validOptSocketVmnetPath() {
        #expect(validateVmnetPath("/opt/socket_vmnet/bin/socket_vmnet"))
    }

    @Test func invalidRootPath() {
        #expect(!validateVmnetPath("/bin/socket_vmnet"))
    }

    @Test func invalidUsrBinPath() {
        #expect(!validateVmnetPath("/usr/bin/socket_vmnet"))
    }

    @Test func invalidEtcPath() {
        #expect(!validateVmnetPath("/etc/socket_vmnet"))
    }

    @Test func invalidTmpPath() {
        #expect(!validateVmnetPath("/tmp/socket_vmnet"))
    }

    @Test func emptyPath() {
        #expect(!validateVmnetPath(""))
    }

    @Test func relativePath() {
        // Relative paths resolve against cwd, which won't match allowed prefixes
        #expect(!validateVmnetPath("socket_vmnet"))
    }

    @Test func pathWithTrailingSlashOnly() {
        #expect(!validateVmnetPath("/"))
    }

    @Test func pathPrefixPartialMatch() {
        // "/opt/homebrewfake" should NOT match "/opt/homebrew/"
        #expect(!validateVmnetPath("/opt/homebrewfake/bin/socket_vmnet"))
    }
}

// MARK: - Extended XPC Round-trip Tests

/// Extended tests for XPC protocol methods beyond what HelperXPCTests covers.
/// Uses an anonymous XPC listener to test all protocol methods in-process.
@Suite final class HelperXPCExtendedTests {
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

    @Test func startBridgeValid() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func startBridgeInvalidInterface() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "en0;bad") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
        #expect(result.1 != nil)
    }

    @Test func startBridgeEmptyInterface() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.startBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
    }

    // MARK: - stopBridge

    @Test func stopBridgeValid() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func stopBridgeInvalidInterface() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.stopBridge(interface: "") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
    }

    // MARK: - bridgeStatus

    @Test func bridgeStatusValid() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "en0") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        #expect(!result.0)
        #expect(result.1 == "not_installed")
    }

    @Test func bridgeStatusInvalidInterface() async throws {
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

    @Test func getAllBridgeStatesReturnsJSON() async throws {
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

    @Test func removeBridgeInvalidInterface() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: "en0/../../etc") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
        #expect(result.1 != nil)
    }

    @Test func removeBridgeInterfaceTooLong() async throws {
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

    @Test func concurrentPings() async throws {
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
