import Foundation
import Testing
@testable import BarkVisorCore

struct RuntimeUUIDTests {
    @Test func `human readable ID maps to a stable QEMU UUID`() {
        let first = QEMUBuilder.runtimeUUID("prod-vm")
        #expect(UUID(uuidString: first) != nil)
        #expect(first == QEMUBuilder.runtimeUUID("prod-vm"))
        #expect(QEMUBuilder.runtimeUUID("11111111-1111-4111-8111-111111111111") == "11111111-1111-4111-8111-111111111111")
        #expect(QEMUArgv.reconnectDecision(pidAlive: true, executableIsQEMU: true, argvUUID: first, vmID: "prod-vm") == .adopt)
    }
}
