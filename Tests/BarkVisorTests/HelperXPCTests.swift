import BarkVisorHelperProtocol
import XCTest

/// In-process handler matching the real BarkVisorHelper implementation.
private class TestHelperHandler: NSObject, HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void) {
        reply("1.0.0")
    }

    func ping(reply: @escaping (String) -> Void) {
        reply("Hello from BarkVisorHelper!")
    }

    func installBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        // Validate interface name like the real handler
        guard !interface.isEmpty,
              interface.count <= 15,
              interface.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            reply(false, "Invalid interface name")
            return
        }
        reply(true, nil)
    }

    func removeBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        guard !interface.isEmpty,
              interface.allSatisfy({ $0.isLetter || $0.isNumber })
        else {
            reply(false, "Invalid interface name")
            return
        }
        reply(true, nil)
    }

    func startBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        reply(true, nil)
    }

    func stopBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
        reply(true, nil)
    }

    func bridgeStatus(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    ) {
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

private class TestListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection,
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = TestHelperHandler()
        connection.resume()
        return true
    }
}

final class HelperXPCTests: XCTestCase {
    private var listener: NSXPCListener?
    private var listenerDelegate: TestListenerDelegate?
    private var connection: NSXPCConnection?

    override func setUp() {
        super.setUp()
        // Anonymous listener — no launchd registration needed
        listenerDelegate = TestListenerDelegate()
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

    func testPing() async throws {
        let p = try proxy()
        let message: String = try await withCheckedThrowingContinuation { cont in
            p.ping { reply in
                cont.resume(returning: reply)
            }
        }
        XCTAssertEqual(message, "Hello from BarkVisorHelper!")
    }

    func testGetVersion() async throws {
        let p = try proxy()
        let version: String = try await withCheckedThrowingContinuation { cont in
            p.getVersion { reply in
                cont.resume(returning: reply)
            }
        }
        XCTAssertEqual(version, "1.0.0")
    }

    func testInstallBridge() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.installBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
    }

    func testInstallBridgeInvalidInterface() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.installBridge(interface: "en0; rm -rf /") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertNotNil(result.1)
    }

    func testRemoveBridge() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        XCTAssertTrue(result.0)
        XCTAssertNil(result.1)
    }

    func testBridgeStatus() async throws {
        let p = try proxy()
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "en0") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "not_installed")
    }
}
