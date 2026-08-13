import Foundation

public struct PairingHTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }
}

public protocol PairingHTTPClient: Sendable {
    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse
}

public struct URLSessionPairingHTTPClient: PairingHTTPClient {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(APIContract.version), forHTTPHeaderField: APIContract.versionHeaderName)
        request.timeoutInterval = timeout
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.redeemFailed(status: 502, reason: "Non-HTTP pairing response")
        }
        return PairingHTTPResponse(status: http.statusCode, body: data)
    }
}
