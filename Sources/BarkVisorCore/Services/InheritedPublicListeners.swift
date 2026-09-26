import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum InheritedPublicListeners {
    public static func release(ports: [Int]) {
        #if !os(Windows)
            let wanted = Set(ports.compactMap { port -> UInt16? in
                guard (1 ... 65_535).contains(port) else { return nil }
                return UInt16(port)
            })
            guard !wanted.isEmpty else { return }
            for fd in fileDescriptors() where wanted.contains(listeningPort(fd) ?? 0) {
                _ = close(fd)
            }
        #else
            _ = ports
        #endif
    }

    #if !os(Windows)
        private static func fileDescriptors() -> [Int32] {
            #if os(Linux)
                let names = (try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd")) ?? []
                return names.compactMap { Int32($0) }.filter { $0 > 2 }
            #else
                let size = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
                guard size > 0 else { return [] }
                let stride = MemoryLayout<proc_fdinfo>.stride
                var descriptors = Array(repeating: proc_fdinfo(), count: Int(size) / stride + 32)
                let bytes = descriptors.withUnsafeMutableBytes { buffer in
                    proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
                }
                guard bytes > 0 else { return [] }
                return descriptors.prefix(Int(bytes) / stride).map(\.proc_fd).filter { $0 > 2 }
            #endif
        }

        private static func listeningPort(_ fd: Int32) -> UInt16? {
            var storage = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let named = withUnsafeMutablePointer(to: &storage) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    getsockname(fd, sock, &length)
                }
            }
            guard named == 0 else { return nil }
            let domain = Int32(storage.ss_family)
            guard domain == AF_INET || domain == AF_INET6 else { return nil }
            #if canImport(Darwin)
                var info = socket_fdinfo()
                guard proc_pidfdinfo(getpid(), fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                      Int32(info.psi.soi_options) & SO_ACCEPTCONN != 0 else { return nil }
            #else
                var accepting: Int32 = 0
                length = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(fd, SOL_SOCKET, SO_ACCEPTCONN, &accepting, &length) == 0, accepting != 0 else {
                    return nil
                }
            #endif
            if domain == AF_INET {
                var address = sockaddr_in()
                var size = socklen_t(MemoryLayout<sockaddr_in>.size)
                let rc = withUnsafeMutablePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                        getsockname(fd, sock, &size)
                    }
                }
                guard rc == 0 else { return nil }
                return UInt16(bigEndian: address.sin_port)
            }
            var address = sockaddr_in6()
            var size = socklen_t(MemoryLayout<sockaddr_in6>.size)
            let rc = withUnsafeMutablePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                    getsockname(fd, sock, &size)
                }
            }
            guard rc == 0 else { return nil }
            return UInt16(bigEndian: address.sin6_port)
        }
    #endif
}
