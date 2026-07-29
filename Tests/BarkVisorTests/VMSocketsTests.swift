import Foundation
import Testing
@testable import BarkVisorCore

struct VMSocketsTests {
    /// Fixed UUID so reconnect/adoption filename contracts stay byte-stable.
    private static let fixedVMID = "01234567-89ab-cdef-0123-456789abcdef"
    private static let expectedShortID = "01234567-89a"

    @Test func `shortID is first 12 characters of vm id`() {
        let sockets = VMSockets(vmID: Self.fixedVMID)
        #expect(sockets.shortID == Self.expectedShortID)
        #expect(Self.expectedShortID.count == 12)
    }

    @Test func `socket filenames are stable for fixed uuid`() {
        let sockets = VMSockets(vmID: Self.fixedVMID)
        let dir = Config.socketDir.path
        #expect(sockets.vnc.path == "\(dir)/\(Self.expectedShortID)-vnc.sock")
        #expect(sockets.serial.path == "\(dir)/\(Self.expectedShortID)-ser.sock")
        #expect(sockets.qmp.path == "\(dir)/\(Self.expectedShortID)-qmp.sock")
        #expect(sockets.event.path == "\(dir)/\(Self.expectedShortID)-evt.sock")
        #expect(sockets.guestAgent.path == "\(dir)/\(Self.expectedShortID)-ga.sock")
        #expect(sockets.monitor.path == "\(dir)/\(Self.expectedShortID)-mon.sock")
    }

    @Test func `all includes event and guest agent`() {
        let sockets = VMSockets(vmID: Self.fixedVMID)
        #expect(sockets.all.count == 6)
        #expect(sockets.all.contains(sockets.event))
        #expect(sockets.all.contains(sockets.guestAgent))
        #expect(sockets.all.contains(sockets.monitor))
    }

    @Test func `init from qmp path reconstructs sibling sockets`() {
        let primary = VMSockets(vmID: Self.fixedVMID)
        let fromQMP = VMSockets(qmpSocketPath: primary.qmp.path)
        #expect(fromQMP != nil)
        #expect(fromQMP?.shortID == primary.shortID)
        #expect(fromQMP?.event.path == primary.event.path)
        #expect(fromQMP?.guestAgent.path == primary.guestAgent.path)
        #expect(fromQMP?.vnc.path == primary.vnc.path)
        #expect(fromQMP?.serial.path == primary.serial.path)
    }

    @Test func `init from non-qmp path fails`() {
        #expect(VMSockets(qmpSocketPath: "/tmp/foo-evt.sock") == nil)
        #expect(VMSockets(qmpSocketPath: "/tmp/random.sock") == nil)
        #expect(VMSockets(qmpSocketPath: "/tmp/-qmp.sock") == nil) // empty shortID
    }
}
