import BarkVisorHelperProtocol
import Foundation
import Testing

/// Verifies that the HelperProtocol is correctly defined as an ObjC protocol
/// suitable for NSXPCInterface.
@Suite struct HelperProtocolConformanceTests {
    @Test func protocolCanBeUsedWithNSXPCInterface() {
        // This would crash at runtime if the protocol is not properly @objc
        let interface = NSXPCInterface(with: HelperProtocol.self)
        #expect(interface != nil)
    }

    @Test func handlerConformsToProtocol() {
        // Verify a basic NSObject subclass can conform to the protocol
        class MinimalHandler: NSObject, HelperProtocol {
            func getVersion(reply: @escaping (String) -> Void) {
                reply("")
            }
            func ping(reply: @escaping (String) -> Void) {
                reply("")
            }
            func installBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
                reply(false, nil)
            }
            func removeBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
                reply(false, nil)
            }
            func startBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
                reply(false, nil)
            }
            func stopBridge(interface: String, reply: @escaping (Bool, String?) -> Void) {
                reply(false, nil)
            }
            func bridgeStatus(interface: String, reply: @escaping (Bool, String?) -> Void) {
                reply(false, nil)
            }
            func getAllBridgeStates(reply: @escaping (String) -> Void) {
                reply("[]")
            }
            func installUpdate(
                packagePath: String, expectedVersion: String, reply: @escaping (Bool, String?) -> Void,
            ) {
                reply(false, nil)
            }
        }

        let handler = MinimalHandler()
        #expect(handler is HelperProtocol)

        // Verify it can be set as exportedObject
        let listener = NSXPCListener.anonymous()
        let conn = NSXPCConnection(listenerEndpoint: listener.endpoint)
        conn.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        conn.exportedObject = handler
        // If we got here without crash, the conformance is valid
        conn.invalidate()
        listener.invalidate()
    }
}
