import BarkVisorHelperProtocol
import Foundation
import Testing

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

final class HelperXPCTests {
    private let listener: NSXPCListener
    private let listenerDelegate: TestListenerDelegate
    private let connection: NSXPCConnection

    init() {
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

    deinit {
        connection.invalidate()
        listener.invalidate()
    }

    private func proxy() -> HelperProtocol? {
        connection.remoteObjectProxyWithErrorHandler { error in
            Issue.record("XPC error: \(error)")
        } as? HelperProtocol
    }

    @Test func ping() async throws {
        let p = try #require(proxy())
        let message: String = try await withCheckedThrowingContinuation { cont in
            p.ping { reply in
                cont.resume(returning: reply)
            }
        }
        #expect(message == "Hello from BarkVisorHelper!")
    }

    @Test func `get version`() async throws {
        let p = try #require(proxy())
        let version: String = try await withCheckedThrowingContinuation { cont in
            p.getVersion { reply in
                cont.resume(returning: reply)
            }
        }
        #expect(version == "1.0.0")
    }

    @Test func `install bridge`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.installBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func `install bridge invalid interface`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.installBridge(interface: "en0; rm -rf /") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(!result.0)
        #expect(result.1 != nil)
    }

    @Test func `remove bridge`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.removeBridge(interface: "en0") { ok, err in
                cont.resume(returning: (ok, err))
            }
        }
        #expect(result.0)
        #expect(result.1 == nil)
    }

    @Test func `bridge status`() async throws {
        let p = try #require(proxy())
        let result: (Bool, String?) = try await withCheckedThrowingContinuation { cont in
            p.bridgeStatus(interface: "en0") { running, status in
                cont.resume(returning: (running, status))
            }
        }
        #expect(!result.0)
        #expect(result.1 == "not_installed")
    }
}
