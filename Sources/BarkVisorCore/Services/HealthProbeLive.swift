#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif
import Foundation

enum HealthProbeLive {
    static func http(
        host: String,
        port: Int,
        path: String,
        timeout: TimeInterval,
        expectedStatus: Int?,
    ) async -> Bool {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.percentEncodedPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = components.url else { return false }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpShouldSetCookies = false
        // FoundationNetworking exposes waitsForConnectivity as get-only.
        #if canImport(Darwin)
            config.waitsForConnectivity = false
        #endif
        let delegate = HealthProbeRedirectBlocker()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("BarkVisor-health/1", forHTTPHeaderField: "User-Agent")

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            if let expectedStatus {
                return http.statusCode == expectedStatus
            }
            return (200 ... 399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    static func tcp(host: String, port: Int, timeout: TimeInterval) async -> Bool {
        // getaddrinfo + poll are blocking; keep them off the cooperative pool.
        await Task.detached(priority: .utility) {
            tcpBlocking(host: host, port: port, timeout: timeout)
        }.value
    }

    private static func tcpBlocking(host: String, port: Int, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = PlatformSocket.stream

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let list = result else { return false }
        defer { freeaddrinfo(list) }

        var current: UnsafeMutablePointer<addrinfo>? = list
        while let info = current {
            if connectNonblocking(info.pointee, timeout: timeout) {
                return true
            }
            current = info.pointee.ai_next
        }
        return false
    }

    private static func connectNonblocking(_ info: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc = connect(fd, info.ai_addr, info.ai_addrlen)
        if rc == 0 { return true }
        if errno != EINPROGRESS { return false }

        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ms = Int32(min(max(timeout * 1_000, 1), Double(Int32.max)))
        let prc = poll(&pollFD, 1, ms)
        guard prc > 0, (pollFD.revents & Int16(POLLOUT)) != 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 else { return false }
        return err == 0
    }
}

/// Default URLSession follows 3xx; a guest that answers 302 to an internal
/// host would otherwise make the Device fetch that Location. Refuse every hop.
final class HealthProbeRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void,
    ) {
        completionHandler(nil)
    }
}
