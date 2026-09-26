import Foundation
import Testing
@testable import BarkVisorCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if !os(Windows)
    struct SocketAcceptTests {
        @Test func `http clients use blocking IO on a nonblocking listener`() throws {
            let listener = try PublicHTTP.bind(port: 0)
            defer { close(listener.fd) }
            let listenerFlags = fcntl(listener.fd, F_GETFL, 0)
            try #require(listenerFlags >= 0)
            try #require(listenerFlags & O_NONBLOCK != 0)
            let client = socket(AF_INET, PlatformSocket.stream, 0)
            try #require(client >= 0)
            defer { close(client) }
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(listener.port).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    connect(client, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            try #require(connected == 0)
            let accepted = PublicHTTP.accept(listener.fd)
            try #require(accepted >= 0)
            defer { close(accepted) }
            let acceptedFlags = fcntl(accepted, F_GETFL, 0)
            try #require(acceptedFlags >= 0)
            #expect(acceptedFlags & O_NONBLOCK == 0)
            #expect(fcntl(listener.fd, F_GETFL, 0) & O_NONBLOCK != 0)
        }
    }
#endif
