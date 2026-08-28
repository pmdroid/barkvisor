#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Foundation
import NIOCore
import NIOHTTP1

enum SSRFPinnedHopSession {
    static let maxRedirects = 16

    struct FinalResponse {
        let url: URL
        let head: HTTPResponseHead
        let body: AsyncThrowingStream<ByteBuffer, Error>
    }

    static func finalResponse(
        request: URLRequest,
        url: URL,
        pin: PinnedEndpoint,
        allowedHosts: Set<String>?,
        hopClient: SSRFPinnedHopClient,
    ) async throws -> FinalResponse {
        var currentRequest = request
        var currentURL = url
        var currentPin = pin
        var seen: Set<String> = [url.absoluteString]
        for _ in 0 ... maxRedirects {
            try Task.checkCancellation()
            try hopClient.prepare(for: currentPin)
            let (head, body) = try await hopClient.execute(
                request: currentRequest, url: currentURL, pin: currentPin,
            )
            let status = Int(head.status.code)
            let location = head.headers.first(name: "location")
            let nextURL = SSRFGuard.redirectTarget(
                statusCode: status, location: location, from: currentURL,
            )
            if let nextURL,
               SSRFGuard.shouldFollowRedirect(to: nextURL, allowedHosts: allowedHosts),
               let nextPin = try? SSRFPinnedURLProtocol.pinEndpoint(url: nextURL) {
                for try await _ in body {
                    try Task.checkCancellation()
                }
                guard seen.insert(nextURL.absoluteString).inserted else {
                    throw URLError(.httpTooManyRedirects)
                }
                currentPin = nextPin
                currentURL = nextURL
                currentRequest.url = nextURL
                switch status {
                case 301, 302, 303:
                    currentRequest.httpMethod = "GET"
                    currentRequest.httpBody = nil
                default:
                    break
                }
                continue
            }
            return FinalResponse(url: currentURL, head: head, body: body)
        }
        throw URLError(.httpTooManyRedirects)
    }
}
