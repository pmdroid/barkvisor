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
class SSRFPinnedURLProtocol: URLProtocol, @unchecked Sendable {
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
            let pin = try SSRFGuard.pinEndpoint(url: url)
            try Task.checkCancellation()
            try await fetch(request: request, url: url, pin: pin)
        } catch is CancellationError {
            fail(URLError(.cancelled))
        } catch {
            fail(error)
        }
    }

    private func fetch(request: URLRequest, url: URL, pin: PinnedEndpoint) async throws {
        var config = HTTPClient.Configuration()
        config.redirectConfiguration = .disallow
        config.dnsOverride = [pin.originalHost: pin.connectIP]
        config.httpVersion = .http1Only
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : 3_600
        config.timeout = .init(
            connect: .seconds(15),
            read: .seconds(Int64(timeout.rounded(.up))),
        )
        // POSIX sockets: connect() the IP literal. Network.framework is not used
        // so it cannot re-resolve the original hostname at TLS time.
        let http = HTTPClient(
            eventLoopGroup: MultiThreadedEventLoopGroup.singleton,
            configuration: config,
        )
        do {
            try await executePinned(http: http, request: request, url: url, timeout: timeout)
            try await http.shutdown()
        } catch {
            try? await http.shutdown()
            throw error
        }
    }

    private func executePinned(
        http: HTTPClient,
        request: URLRequest,
        url: URL,
        timeout: TimeInterval,
    ) async throws {
        var outbound = HTTPClientRequest(url: url.absoluteString)
        outbound.method = HTTPMethod(rawValue: request.httpMethod ?? "GET")
        if let body = request.httpBody {
            outbound.body = .bytes(body)
        }
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            if name.caseInsensitiveCompare("Host") == .orderedSame { continue }
            outbound.headers.replaceOrAdd(name: name, value: value)
        }

        let response = try await http.execute(outbound, timeout: .seconds(Int64(timeout.rounded(.up))))
        try Task.checkCancellation()

        var headerFields: [String: String] = [:]
        for header in response.headers {
            headerFields[header.name] = header.value
        }
        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: Int(response.status.code),
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
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail(_ error: Error) {
        client?.urlProtocol(self, didFailWithError: error)
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
