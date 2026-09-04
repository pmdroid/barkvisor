import Foundation
import GRDB
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
@testable import BarkVisorCore

struct VMStartHelpersTests {
    private func tempFileURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sock")
    }

    @Test func `wait for socket returns true when file already exists`() async {
        let sock = tempFileURL()
        FileManager.default.createFile(atPath: sock.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: sock) }
        let process = Process()
        #expect(await VMManager.waitForSocket(sock, process: process, pollCount: 5, pollNanos: 1_000))
    }

    @Test func `wait for socket returns false when file never appears`() async {
        let sock = tempFileURL()
        let process = Process()
        #expect(
            await !(VMManager.waitForSocket(sock, process: process, pollCount: 3, pollNanos: 1_000)),
        )
    }

    @Test func `wait for socket returns false when process exits first`() async throws {
        let sock = tempFileURL()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        #expect(
            await !(VMManager.waitForSocket(sock, process: process, pollCount: 5, pollNanos: 1_000)),
        )
    }

    @Test func `assert host ports fails on bound udp hostfwd`() throws {
        let port = try Self.bindUDPEphemeralPort()
        defer { close(port.fd) }
        let vm = try Self.makeVM(portForwards: [
            PortForwardRule(protocol: "udp", hostPort: port.port, guestPort: 53),
        ])
        let error = #expect(throws: BarkVisorError.self) {
            try VMManager.assertHostPortsAvailable(for: vm)
        }
        #expect(error?.code == "port_in_use")
        #expect(error?.errorDescription?.contains("\(port.port)") == true)
    }

    @Test func `assert host ports passes free udp hostfwd`() throws {
        let vm = try Self.makeVM(portForwards: [
            PortForwardRule(protocol: "udp", hostPort: 35_353, guestPort: 53),
        ])
        #expect(throws: Never.self) {
            try VMManager.assertHostPortsAvailable(for: vm)
        }
    }

    private static func bindUDPEphemeralPort() throws -> (fd: Int32, port: Int) {
        #if os(Linux)
            let sockType = Int32(SOCK_DGRAM.rawValue)
        #else
            let sockType = SOCK_DGRAM
        #endif
        let fd = socket(AF_INET, sockType, 0)
        guard fd >= 0 else { throw BarkVisorError.badRequest("test udp socket failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw BarkVisorError.badRequest("test udp bind failed")
        }
        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard nameResult == 0 else {
            close(fd)
            throw BarkVisorError.badRequest("test udp getsockname failed")
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        return (fd, port)
    }

    private static func makeVM(portForwards: [PortForwardRule]) throws -> VM {
        VM(
            id: UUID().uuidString,
            name: "udp-conflict",
            vmType: "linux-arm64",
            state: "stopped",
            cpuCount: 1,
            memoryMb: 512,
            bootDiskId: "disk-udp-test",
            networkId: nil,
            cloudInitPath: nil,
            description: nil,
            bootOrder: nil,
            displayResolution: nil,
            additionalDiskIds: nil,
            uefi: true,
            tpmEnabled: false,
            macAddress: nil,
            sharedPaths: nil,
            portForwards: JSONColumnCoding.encode(portForwards),
            autoCreated: false,
            pendingChanges: false,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
    }
}
