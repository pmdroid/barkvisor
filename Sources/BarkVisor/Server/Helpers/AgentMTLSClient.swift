#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import AsyncHTTPClient
import BarkVisorCore
import Foundation
import NIOHTTP1
import NIOPosix
import NIOSSL

/// mTLS HTTP client for member proxy (PAS-34).
///
/// Uses NIO sockets (not Network.framework) so client certificates work
/// on macOS and Linux. Hostname verification is off because Device certs
/// carry a `barkvisor://device` SAN, not a DNS name; the Home CA is the
/// trust root. A failed call must not touch local SQLite / QEMU.
public struct AgentMTLSClient: HomeDeviceProxyClient {
    public var material: HomeCertificateMaterial
    public var timeoutSeconds: Int64

    public init(material: HomeCertificateMaterial, timeoutSeconds: Int64 = 10) {
        self.material = material
        self.timeoutSeconds = timeoutSeconds
    }

    public func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let ca = try NIOSSLCertificate(bytes: Array(material.caCertificatePEM.utf8), format: .pem)
        let cert = try NIOSSLCertificate(
            bytes: Array(material.deviceCertificatePEM.utf8),
            format: .pem,
        )
        let key = try NIOSSLPrivateKey(bytes: Array(material.deviceKeyPEM.utf8), format: .pem)

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .noHostnameVerification
        tls.trustRoots = .certificates([ca])
        tls.certificateChain = [.certificate(cert)]
        tls.privateKey = .privateKey(key)
        tls.minimumTLSVersion = .tlsv12

        var config = HTTPClient.Configuration()
        config.tlsConfiguration = tls
        config.redirectConfiguration = .disallow
        config.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(timeoutSeconds),
            read: .seconds(timeoutSeconds),
        )

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
        do {
            let response = try await execute(request, on: client)
            try await client.shutdown()
            try await group.shutdownGracefully()
            return response
        } catch let error as HomeDeviceProxyError {
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            throw error
        } catch {
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
    }

    private func execute(
        _ request: HomeDeviceProxyRequest,
        on client: HTTPClient,
    ) async throws -> HomeDeviceProxyResponse {
        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = HTTPMethod(rawValue: request.method.uppercased())
        for (name, value) in request.headers {
            outbound.headers.replaceOrAdd(name: name, value: value)
        }
        if let body = request.body {
            outbound.body = .bytes(body)
        }
        let response: HTTPClientResponse
        do {
            response = try await client.execute(outbound, timeout: .seconds(timeoutSeconds))
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        let buffer = try await response.body.collect(upTo: HomeDeviceProxy.maxBodyBytes)
        let headers = response.headers.map { ($0.name, $0.value) }
        return HomeDeviceProxyResponse(
            status: Int(response.status.code),
            headers: headers,
            body: Data(buffer.readableBytesView),
        )
    }
}

/// Loopback HTTP client for self-proxy and the agent-plane local forward.
public struct LocalHostProxyClient: HomeDeviceProxyClient {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 10) {
        self.timeout = timeout
    }

    public func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        var outbound = URLRequest(url: request.url)
        outbound.httpMethod = request.method
        outbound.timeoutInterval = timeout
        for (name, value) in request.headers {
            outbound.setValue(value, forHTTPHeaderField: name)
        }
        outbound.httpBody = request.body
        do {
            let (data, response) = try await LocalHostProxySession.shared.data(for: outbound)
            guard let http = response as? HTTPURLResponse else {
                throw HomeDeviceProxyError.unreachable("Non-HTTP local response")
            }
            let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
                guard let name = key as? String else { return nil }
                return (name, String(describing: value))
            }
            return HomeDeviceProxyResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as HomeDeviceProxyError {
            throw error
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
    }
}

private enum LocalHostProxySession {
    static let shared: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        #if canImport(Darwin)
            config.waitsForConnectivity = false
        #endif
        return URLSession(
            configuration: config,
            delegate: LocalHostRedirectBlocker.shared,
            delegateQueue: nil,
        )
    }()
}

private final class LocalHostRedirectBlocker: NSObject, URLSessionDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    static let shared = LocalHostRedirectBlocker()

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
