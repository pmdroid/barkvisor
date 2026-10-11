import Foundation
import Testing
@testable import BarkVisorCore

struct SocketIdentityTests {
    @Test func `equal prefixes still get distinct endpoints`() {
        let a = "11111111-1111-4111-8111-111111111111"
        let b = "11111111-1111-4222-8222-222222222222"
        let left = VMSockets(vmID: a)
        let right = VMSockets(vmID: b)
        #expect(left.qmp.path != right.qmp.path)
        #expect(left.owned(by: a))
        #expect(!left.owned(by: b))
        #expect(right.owned(by: b))
        let reconstructed = VMSockets(qmpSocketPath: left.qmp.path)
        #expect(reconstructed?.qmp.path == left.qmp.path)
        let legacy = VMSockets(qmpSocketPath: Config.socketDir.appendingPathComponent("\(a.prefix(12))-qmp.sock").path)
        #expect(legacy?.owned(by: a) == true)
    }
}
