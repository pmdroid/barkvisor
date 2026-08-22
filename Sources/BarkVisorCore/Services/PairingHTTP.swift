#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
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

/// Inputs for copying Home login over the agent plane (PAS-283).
public struct PairingIdentityFetch: Sendable {
    public var host: String
    public var agentPort: Int
    public var material: HomeCertificateMaterial
    public var issuedCertificatePEM: String
    public var trustCertificatePEM: String

    public init(
        host: String,
        agentPort: Int,
        material: HomeCertificateMaterial,
        issuedCertificatePEM: String,
        trustCertificatePEM: String,
    ) {
        self.host = host
        self.agentPort = agentPort
        self.material = material
        self.issuedCertificatePEM = issuedCertificatePEM
        self.trustCertificatePEM = trustCertificatePEM
    }
}

/// mTLS fetch of jwt-secret + admin hash. Not the cleartext HTTP redeem.
public protocol PairingIdentityClient: Sendable {
    func fetchSharedIdentity(_ request: PairingIdentityFetch) async throws -> PairingSharedIdentity
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
        // Do not use URLSession.shared: it follows redirects and would skip
        // PairingPayload.httpAPIURL / blocked-host checks (LAN 302 → loopback).
        let (data, response) = try await PairingHTTPSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PairingError.redeemFailed(status: 502, reason: "Non-HTTP pairing response")
        }
        return PairingHTTPResponse(status: http.statusCode, body: data)
    }
}

/// Pairing join is LAN HTTP to a pinned host. Redirects are refused so a
/// QR host that passed host validation cannot bounce to loopback or metadata.
private enum PairingHTTPSession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        #if canImport(Darwin)
            config.waitsForConnectivity = false
        #endif
        return URLSession(
            configuration: config,
            delegate: PairingHTTPRedirectBlocker.shared,
            delegateQueue: nil,
        )
    }()
}

private final class PairingHTTPRedirectBlocker: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = PairingHTTPRedirectBlocker()

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
