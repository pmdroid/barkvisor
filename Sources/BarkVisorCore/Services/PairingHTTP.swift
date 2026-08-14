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
    func get(url: URL) async throws -> PairingHTTPResponse
    func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse
}

public struct URLSessionPairingHTTPClient: PairingHTTPClient {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func get(url: URL) async throws -> PairingHTTPResponse {
        try await send(url: url, method: "GET", body: nil)
    }

    public func postJSON(url: URL, body: Data) async throws -> PairingHTTPResponse {
        try await send(url: url, method: "POST", body: body)
    }

    private func send(url: URL, method: String, body: Data?) async throws -> PairingHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(String(APIContract.version), forHTTPHeaderField: APIContract.versionHeaderName)
        request.timeoutInterval = timeout
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.redeemFailed(status: 502, reason: "Non-HTTP pairing response")
        }
        return PairingHTTPResponse(status: http.statusCode, body: data)
    }
}
