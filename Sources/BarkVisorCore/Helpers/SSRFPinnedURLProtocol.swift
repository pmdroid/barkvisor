#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import AsyncHTTPClient
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

/// Resolves once, validates, then fetches via AsyncHTTPClient `dnsOverride` so
/// TCP uses the approved IP while Host and TLS SNI stay on the original hostname.
/// Each 3xx Location is re-pinned with ``SSRFGuard.pinEndpoint`` before connect.
/// One `HTTPClient` is reused for the fetch; a new pin (new host or IP) replaces
/// it because `dnsOverride` is fixed at client init. Shutdown runs once at the end.
class SSRFPinnedURLProtocol: URLProtocol, @unchecked Sendable {
    static let timeoutHeader = "X-BarkVisor-SSRF-Timeout"
    private static let maxRedirects = 16
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return Config.allowedURLSchemes.contains(scheme)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let box = LoadBox(proto: self, request: request)
        work = Task {
            await box.run()
        }
    }

    override func stopLoading() {
        work?.cancel()
        work = nil
    }

    fileprivate func performLoad(_ request: URLRequest) async {
        guard let url = request.url else {
            fail(URLError(.badURL))
            return
        }
        do {
            let pin = try Self.pinEndpoint(url: url)
            try Task.checkCancellation()
            try await fetch(request: request, url: url, pin: pin)
        } catch is CancellationError {
            fail(URLError(.cancelled))
        } catch {
            fail(error)
        }
    }

    private func fetch(request: URLRequest, url: URL, pin: PinnedEndpoint) async throws {
        var currentRequest = request
        var currentURL = url
        var currentPin = pin
        var seen: Set<String> = [url.absoluteString]
        let hopClient = SSRFPinnedHopClient(timeout: resourceTimeout(from: request))

        do {
            for _ in 0 ... Self.maxRedirects {
                try Task.checkCancellation()
                if let next = try await performHop(
                    request: currentRequest, url: currentURL, pin: currentPin, hopClient: hopClient,
                ) {
                    guard seen.insert(next.url.absoluteString).inserted else {
                        throw URLError(.httpTooManyRedirects)
                    }
                    currentPin = try Self.pinEndpoint(url: next.url)
                    currentURL = next.url
                    currentRequest.url = next.url
                    switch next.status {
                    case 301, 302, 303:
                        currentRequest.httpMethod = "GET"
                        currentRequest.httpBody = nil
                    default:
                        break
                    }
                    continue
                }
                await hopClient.shutdown()
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            throw URLError(.httpTooManyRedirects)
        } catch {
            await hopClient.shutdown()
            throw error
        }
    }

    private struct RedirectHop {
        let url: URL
        let status: Int
    }

    /// Returns the next hop when following a 3xx; nil after delivering the final response.
    private func performHop(
        request: URLRequest, url: URL, pin: PinnedEndpoint, hopClient: SSRFPinnedHopClient,
    ) async throws -> RedirectHop? {
        let http = try await hopClient.client(for: pin)
        return try await sendHop(
            http: http, request: request, url: url, timeout: hopClient.timeout,
        )
    }

    private func resourceTimeout(from request: URLRequest) -> TimeInterval {
        if let raw = request.value(forHTTPHeaderField: Self.timeoutHeader),
           let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        return request.timeoutInterval > 0 ? request.timeoutInterval : 60
    }

    private func sendHop(
        http: HTTPClient,
        request: URLRequest,
        url: URL,
        timeout: TimeInterval,
    ) async throws -> RedirectHop? {
        var outbound = HTTPClientRequest(url: url.absoluteString)
        outbound.method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        if let body = request.httpBody {
            outbound.body = .bytes(body)
        }
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
            if name.caseInsensitiveCompare(Self.timeoutHeader) == .orderedSame { continue }
            outbound.headers.replaceOrAdd(name: name, value: value)
        }

        let response = try await http.execute(outbound, timeout: .seconds(Int64(timeout.rounded(.up))))
        try Task.checkCancellation()
        let status = Int(response.status.code)
        let location = response.headers.first(name: "location")
        let nextURL = SSRFGuard.redirectTarget(
            statusCode: status, location: location, from: url,
        )
        if let nextURL, SSRFGuard.shouldFollowRedirect(to: nextURL),
           (try? Self.pinEndpoint(url: nextURL)) != nil {
            for try await _ in response.body {
                try Task.checkCancellation()
            }
            return RedirectHop(url: nextURL, status: status)
        }

        var headerFields: [String: String] = [:]
        for header in response.headers {
            headerFields[header.name] = header.value
        }
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headerFields,
        )
        else {
            throw URLError(.badServerResponse)
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        for try await buffer in response.body {
            try Task.checkCancellation()
            let data = Data(buffer.readableBytesView)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
        }
        return nil
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
    }
}

/// One AsyncHTTPClient for a Library fetch. `HTTPClient.Configuration.dnsOverride`
/// cannot change after init, so a pin that adds a host or changes an IP replaces
/// the client. Hops that keep the same mapping reuse it.
private final class SSRFPinnedHopClient: @unchecked Sendable {
    let timeout: TimeInterval
    private var http: HTTPClient?
    private var dnsOverride: [String: String] = [:]
    private var didShutdown = false

    init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    func client(for pin: PinnedEndpoint) async throws -> HTTPClient {
        if didShutdown {
            throw URLError(.cancelled)
        }
        let next = dnsOverride.merging(
            [pin.originalHost: pin.connectIP],
            uniquingKeysWith: { _, new in new },
        )
        if let http, dnsOverride == next {
            return http
        }
        if let http {
            await Self.shutdownAndCount(http)
        }
        dnsOverride = next
        let created = SSRFPinnedURLProtocol.makeHTTPClient(
            dnsOverride: next, timeout: timeout,
        )
        http = created
        return created
    }

    func shutdown() async {
        guard !didShutdown else { return }
        didShutdown = true
        guard let http else { return }
        self.http = nil
        await Self.shutdownAndCount(http)
    }

    /// Counts a teardown only when `HTTPClient.shutdown()` returns.
    private static func shutdownAndCount(_ http: HTTPClient) async {
        do {
            try await http.shutdown()
            SSRFPinnedURLProtocol.finishShutdown(succeeded: true)
        } catch {
            SSRFPinnedURLProtocol.finishShutdown(succeeded: false)
        }
    }
}

#if DEBUG
    private final class SSRFPinnedURLProtocolHooks: @unchecked Sendable {
        let lock = NSLock()
        var httpClientsCreated = 0
        var httpClientsShutdown = 0
        var dnsOverrides: [[String: String]] = []
        var pinnedURLs: [String] = []
        var pinEndpointOverride: (@Sendable (URL) throws -> PinnedEndpoint)?
    }
#endif

extension SSRFPinnedURLProtocol {
    #if DEBUG
        private static let hooks = SSRFPinnedURLProtocolHooks()

        static var httpClientsCreated: Int {
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            return hooks.httpClientsCreated
        }

        static var httpClientsShutdown: Int {
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            return hooks.httpClientsShutdown
        }

        static var dnsOverrides: [[String: String]] {
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            return hooks.dnsOverrides
        }

        static var pinnedURLs: [String] {
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            return hooks.pinnedURLs
        }

        static var pinEndpointOverride: (@Sendable (URL) throws -> PinnedEndpoint)? {
            get {
                hooks.lock.lock()
                defer { hooks.lock.unlock() }
                return hooks.pinEndpointOverride
            }
            set {
                hooks.lock.lock()
                defer { hooks.lock.unlock() }
                hooks.pinEndpointOverride = newValue
            }
        }

        static func resetTestHooks() {
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            hooks.httpClientsCreated = 0
            hooks.httpClientsShutdown = 0
            hooks.dnsOverrides = []
            hooks.pinnedURLs = []
            hooks.pinEndpointOverride = nil
        }
    #endif

    static func pinEndpoint(url: URL) throws -> PinnedEndpoint {
        #if DEBUG
            hooks.lock.lock()
            let override = hooks.pinEndpointOverride
            hooks.lock.unlock()
            let pin = try override?(url) ?? SSRFGuard.pinEndpoint(url: url)
            hooks.lock.lock()
            hooks.pinnedURLs.append(url.absoluteString)
            hooks.lock.unlock()
            return pin
        #else
            return try SSRFGuard.pinEndpoint(url: url)
        #endif
    }

    fileprivate static func makeHTTPClient(dnsOverride: [String: String], timeout: TimeInterval) -> HTTPClient {
        var config = HTTPClient.Configuration()
        config.redirectConfiguration = .disallow
        config.dnsOverride = dnsOverride
        config.httpVersion = .http1Only
        config.timeout = .init(
            connect: .seconds(15),
            read: .seconds(Int64(timeout.rounded(.up))),
        )
        #if DEBUG
            hooks.lock.lock()
            hooks.httpClientsCreated += 1
            hooks.dnsOverrides.append(dnsOverride)
            hooks.lock.unlock()
        #endif
        // POSIX sockets: connect() the IP literal. Network.framework is not used
        // so it cannot re-resolve the original hostname at TLS time.
        return HTTPClient(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            configuration: config,
        )
    }

    /// Increments the test shutdown counter only after a successful teardown.
    static func finishShutdown(succeeded: Bool) {
        #if DEBUG
            guard succeeded else { return }
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            hooks.httpClientsShutdown += 1
        #endif
    }
}

private final class LoadBox: @unchecked Sendable {
    weak var proto: SSRFPinnedURLProtocol?
    let request: URLRequest

    init(proto: SSRFPinnedURLProtocol, request: URLRequest) {
        self.proto = proto
        self.request = request
    }

    func run() async {
        await proto?.performLoad(request)
    }
}
