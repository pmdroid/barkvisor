#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation
import NIOCore
import NIOHTTP1

/// Resolves once, validates, then connects to the approved IP while Host and TLS SNI
/// stay on the original hostname. Each 3xx Location is re-pinned with
/// ``SSRFGuard.pinEndpoint`` before connect. One hop client is reused for the fetch
/// and shut down once at the end; per-hop re-pin does not recreate it.
class SSRFPinnedURLProtocol: URLProtocol, @unchecked Sendable {
    static let timeoutHeader = "X-BarkVisor-SSRF-Timeout"
    static let allowedHostsHeader = "X-BarkVisor-SSRF-Allowed-Hosts"
    private static let maxRedirects = 16
    private var work: Task<Void, Never>?
    private let finishLock = NSLock()
    private var didFinish = false

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme?.lowercased() else { return false }
        return Config.allowedURLSchemes.contains(scheme)
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        var req = request
        if let raw = headerValue(allowedHostsHeader, in: request) {
            req.setValue(raw, forHTTPHeaderField: allowedHostsHeader)
        }
        return req
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
            if let allowed = Self.allowedHosts(in: request),
               let reason = SSRFGuard.fetchRejection(for: url, allowedHosts: allowed) {
                throw SSRFPinError.rejected(reason)
            }
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
                    currentPin = next.pin
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
                notifyFinish()
                await hopClient.shutdown()
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
        let pin: PinnedEndpoint
    }

    /// Returns the next hop when following a 3xx; nil after delivering the final response.
    private func performHop(
        request: URLRequest, url: URL, pin: PinnedEndpoint, hopClient: SSRFPinnedHopClient,
    ) async throws -> RedirectHop? {
        try hopClient.prepare(for: pin)
        return try await sendHop(
            hopClient: hopClient, request: request, url: url, pin: pin,
        )
    }

    static func allowedHosts(in request: URLRequest?) -> Set<String>? {
        guard let request, let raw = headerValue(allowedHostsHeader, in: request) else { return nil }
        let hosts = Set(
            raw.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }.filter { !$0.isEmpty },
        )
        return hosts.isEmpty ? nil : hosts
    }

    static func headerValue(_ name: String, in request: URLRequest) -> String? {
        if let value = request.value(forHTTPHeaderField: name), !value.isEmpty {
            return value
        }
        for (key, value) in request.allHTTPHeaderFields ?? [:] {
            if key.caseInsensitiveCompare(name) == .orderedSame, !value.isEmpty {
                return value
            }
        }
        if let stored = property(forKey: name, in: request) as? String, !stored.isEmpty {
            return stored
        }
        return nil
    }

    private func resourceTimeout(from request: URLRequest) -> TimeInterval {
        if let raw = Self.headerValue(Self.timeoutHeader, in: request),
           let seconds = TimeInterval(raw), seconds > 0 {
            return seconds
        }
        return request.timeoutInterval > 0 ? request.timeoutInterval : 60
    }

    private func sendHop(
        hopClient: SSRFPinnedHopClient,
        request: URLRequest,
        url: URL,
        pin: PinnedEndpoint,
    ) async throws -> RedirectHop? {
        let (head, body) = try await hopClient.execute(request: request, url: url, pin: pin)
        try Task.checkCancellation()
        let status = Int(head.status.code)
        let location = head.headers.first(name: "location")
        let nextURL = SSRFGuard.redirectTarget(
            statusCode: status, location: location, from: url,
        )
        let allowed = Self.allowedHosts(in: request)
        if let nextURL,
           SSRFGuard.shouldFollowRedirect(to: nextURL, allowedHosts: allowed),
           let nextPin = try? Self.pinEndpoint(url: nextURL) {
            for try await _ in body {
                try Task.checkCancellation()
            }
            return RedirectHop(url: nextURL, status: status, pin: nextPin)
        }

        let dropLocation = nextURL != nil
        var headerFields: [String: String] = [:]
        for header in head.headers {
            if dropLocation, header.name.lowercased() == "location" { continue }
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
        let protoClient = client
        protoClient?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        var delivered = 0
        for try await buffer in body {
            try Task.checkCancellation()
            let data = Data(buffer.readableBytesView)
            delivered += data.count
            if !data.isEmpty {
                protoClient?.urlProtocol(self, didLoad: data)
            }
        }
        if let expected = Int(head.headers.first(name: "content-length") ?? ""),
           expected > 0, delivered == 0 {
            throw URLError(.cannotParseResponse)
        }
        return nil
    }

    private func notifyFinish() {
        finishOnce { client?.urlProtocolDidFinishLoading(self) }
    }

    private func fail(_ error: Error) {
        finishOnce { client?.urlProtocol(self, didFailWithError: error) }
    }

    /// URLSession.async `data(from:)` resumes once. stopLoading after a pin reject
    /// would otherwise fail again (Linux FoundationNetworking: continuation misuse / SIGILL).
    private func finishOnce(_ body: () -> Void) {
        finishLock.lock()
        defer { finishLock.unlock() }
        guard !didFinish else { return }
        didFinish = true
        body()
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

    static func recordClientCreated() {
        #if DEBUG
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            hooks.httpClientsCreated += 1
        #endif
    }

    static func recordDNSOverride(_ dnsOverride: [String: String]) {
        #if DEBUG
            hooks.lock.lock()
            defer { hooks.lock.unlock() }
            hooks.dnsOverrides.append(dnsOverride)
        #endif
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
