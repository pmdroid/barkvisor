import Foundation
import Testing
@testable import BarkVisorCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

#if !os(Windows)
    struct SocketDisconnectTests {
        @Test(arguments: [false, true])
        func `listener writes do not signal when the peer disconnects`(publicHTTP: Bool) throws {
            var sockets: [Int32] = [-1, -1]
            try #require(socketpair(PlatformSocket.unixFamily, PlatformSocket.stream, 0, &sockets) == 0)
            defer { close(sockets[0]) }
            close(sockets[1])
            var blocked = sigset_t()
            sigemptyset(&blocked)
            sigaddset(&blocked, SIGPIPE)
            var original = sigset_t()
            try #require(pthread_sigmask(SIG_BLOCK, &blocked, &original) == 0)
            defer {
                var pending = sigset_t()
                sigpending(&pending)
                if sigismember(&pending, SIGPIPE) == 1 {
                    var received: Int32 = 0
                    sigwait(&blocked, &received)
                }
                pthread_sigmask(SIG_SETMASK, &original, nil)
            }
            if publicHTTP {
                PublicHTTP.write(sockets[0], "response")
            } else {
                #expect(throws: LocalManagementError.connectionLost) {
                    try LocalManagementPOSIX.writeFrame(fd: sockets[0], payload: Data("response".utf8))
                }
            }
            var pending = sigset_t()
            try #require(sigpending(&pending) == 0)
            #expect(sigismember(&pending, SIGPIPE) == 0)
        }
    }
#endif
