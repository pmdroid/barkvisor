import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct VaporListenerOwnershipTests {
    @Test func `bark server owns the public listeners and the daemon stays off tcp`() {
        #expect(VaporServer.ownsPublicListeners(role: .barkServer))
        #expect(VaporServer.ownsPublicListeners(role: .combined))
        #expect(!VaporServer.ownsPublicListeners(role: .barkDaemon))
        #expect(!VaporListenerGate.authoritativeStartAllowed(role: .barkServer))
        #expect(VaporListenerGate.authoritativeStartAllowed(role: .combined))
    }
}
