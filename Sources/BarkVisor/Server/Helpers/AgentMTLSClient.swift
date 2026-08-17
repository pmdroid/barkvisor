#if canImport(CryptoKit)
    import CryptoKit
#else
    import Crypto
#endif
import AsyncHTTPClient
import BarkVisorCore
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL

public struct LibraryDepotStreamResult: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var bytesWritten: Int64
    public var sha256: String

    public init(status: Int, headers: [(String, String)], bytesWritten: Int64, sha256: String) {
        self.status = status
        self.headers = headers
        self.bytesWritten = bytesWritten
        self.sha256 = sha256
    }
}

/// mTLS HTTP client for member proxy (PAS-34).
///
/// Uses NIO sockets (not Network.framework) so client certificates work
/// on macOS and Linux. Hostname verification is off because Device certs
/// carry a `barkvisor://device` SAN, not a DNS name; the Home CA is the
/// trust root. A failed call must not touch local SQLite / QEMU.
///
/// Event loops and TLS-backed HTTP clients are process-scoped (same idea
/// as `LocalHostProxyHTTP.shared`) so concurrent dashboard proxies do
/// not spawn a NIO thread pool per request.
public struct AgentMTLSClient: HomeDeviceProxyClient {
    public var material: HomeCertificateMaterial
    public var presentationCertificatePEM: String
    public var trustCertificatePEMs: [String]
    public var timeoutSeconds: Int64

    public init(
        material: HomeCertificateMaterial,
        presentationCertificatePEM: String? = nil,
        trustCertificatePEMs: [String] = [],
        timeoutSeconds: Int64 = 10,
    ) {
        self.material = material
        self.presentationCertificatePEM = presentationCertificatePEM ?? material.deviceCertificatePEM
        self.trustCertificatePEMs = trustCertificatePEMs.isEmpty
            ? [material.caCertificatePEM]
            : trustCertificatePEMs
        self.timeoutSeconds = timeoutSeconds
    }

    public func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        let client = try AgentMTLSRuntime.shared.client(
            for: material,
            presentationCertificatePEM: presentationCertificatePEM,
            trustCertificatePEMs: trustCertificatePEMs,
            timeoutSeconds: timeoutSeconds,
        )
        do {
            return try await execute(request, on: client)
        } catch let error as HomeDeviceProxyError {
            throw error
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
    }

    /// Stream a GET onto disk. Used only for Library depot bytes (PAS-176).
    /// Does not collect the body into the 10 MiB proxy buffer.
    public func streamGet(
        url: URL,
        to destination: URL,
        connectTimeoutSeconds: Int64 = 10,
        readTimeoutSeconds: Int64 = 1_800,
        maxBytes: Int64 = LibraryDepotStreamLimits.defaultMaxBytes,
    ) async throws -> LibraryDepotStreamResult {
        let client = try AgentMTLSRuntime.shared.client(
            for: material,
            presentationCertificatePEM: presentationCertificatePEM,
            trustCertificatePEMs: trustCertificatePEMs,
            timeoutSeconds: connectTimeoutSeconds,
            readTimeoutSeconds: readTimeoutSeconds,
        )
        var outbound = HTTPClientRequest(url: url.absoluteString)
        outbound.method = .GET
        outbound.headers.replaceOrAdd(name: "Accept", value: "application/octet-stream")
        outbound.headers.replaceOrAdd(
            name: APIContract.versionHeaderName,
            value: String(APIContract.version),
        )
        let response: HTTPClientResponse
        do {
            response = try await client.execute(outbound, timeout: .seconds(readTimeoutSeconds))
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        let headers = response.headers.map { ($0.name, $0.value) }
        let status = Int(response.status.code)
        guard status == 200 else {
            _ = try? await collectProxyBody(response.body, maxBytes: 65_536)
            return LibraryDepotStreamResult(
                status: status, headers: headers, bytesWritten: 0, sha256: "",
            )
        }

        let part = destination.appendingPathExtension("part")
        if FileManager.default.fileExists(atPath: part.path) {
            try FileManager.default.removeItem(at: part)
        }
        FileManager.default.createFile(atPath: part.path, contents: nil)
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: part)
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        defer { try? handle.close() }

        let contentLength: Int64? = response.headers.first(name: "Content-Length").flatMap { Int64($0) }
        let cap: Int64
        do {
            cap = try LibraryDepotStreamLimits.writeCap(contentLength: contentLength, maxBytes: maxBytes)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw error
        }

        var hasher = SHA256()
        var written: Int64 = 0
        do {
            for try await buffer in response.body {
                let data = Data(buffer.readableBytesView)
                written += Int64(data.count)
                if written > cap {
                    try? FileManager.default.removeItem(at: part)
                    throw BarkVisorError.downloadFailed(
                        "depot stream exceeded size cap (\(written) > \(cap))",
                    )
                }
                try handle.write(contentsOf: data)
                hasher.update(data: data)
            }
        } catch let error as BarkVisorError {
            try? FileManager.default.removeItem(at: part)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        let digest = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        do {
            try FileManager.default.moveItem(at: part, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: part)
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        return LibraryDepotStreamResult(
            status: status, headers: headers, bytesWritten: written, sha256: digest,
        )
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
        let buffer = try await collectProxyBody(response.body, maxBytes: HomeDeviceProxy.maxBodyBytes)
        let headers = response.headers.map { ($0.name, $0.value) }
        return HomeDeviceProxyResponse(
            status: Int(response.status.code),
            headers: headers,
            body: Data(buffer.readableBytesView),
        )
    }
}

/// Process-wide NIO + HTTPClient cache. Clients are never shut down; the
/// daemon owns them for its lifetime, matching `LocalHostProxyHTTP`.
private final class AgentMTLSRuntime: @unchecked Sendable {
    static let shared = AgentMTLSRuntime()
    /// NIO sockets (not Network.framework) so `certificateChain` works on macOS.
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private let lock = NSLock()
    private var clients: [String: HTTPClient] = [:]

    func client(
        for material: HomeCertificateMaterial,
        presentationCertificatePEM: String,
        trustCertificatePEMs: [String],
        timeoutSeconds: Int64,
        readTimeoutSeconds: Int64? = nil,
    ) throws -> HTTPClient {
        let readTimeout = readTimeoutSeconds ?? timeoutSeconds
        let trustKey = trustCertificatePEMs.map(\.count).map(String.init).joined(separator: ",")
        let key =
            "\(material.caFingerprint)|\(presentationCertificatePEM.count)|\(trustKey)|\(timeoutSeconds)|\(readTimeout)"
        lock.lock()
        defer { lock.unlock() }
        if let existing = clients[key] {
            return existing
        }
        let created = try makeClient(
            material: material,
            presentationCertificatePEM: presentationCertificatePEM,
            trustCertificatePEMs: trustCertificatePEMs,
            timeoutSeconds: timeoutSeconds,
            readTimeoutSeconds: readTimeout,
        )
        clients[key] = created
        return created
    }

    private func makeClient(
        material: HomeCertificateMaterial,
        presentationCertificatePEM: String,
        trustCertificatePEMs: [String],
        timeoutSeconds: Int64,
        readTimeoutSeconds: Int64,
    ) throws -> HTTPClient {
        let roots = try trustCertificatePEMs.map { pem in
            try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
        }
        let cert = try NIOSSLCertificate(
            bytes: Array(presentationCertificatePEM.utf8),
            format: .pem,
        )
        let key = try NIOSSLPrivateKey(bytes: Array(material.deviceKeyPEM.utf8), format: .pem)

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .noHostnameVerification
        tls.trustRoots = .certificates(roots)
        tls.certificateChain = [.certificate(cert)]
        tls.privateKey = .privateKey(key)
        tls.minimumTLSVersion = .tlsv12

        var config = HTTPClient.Configuration()
        config.tlsConfiguration = tls
        config.redirectConfiguration = .disallow
        config.timeout = HTTPClient.Configuration.Timeout(
            connect: .seconds(timeoutSeconds),
            read: .seconds(readTimeoutSeconds),
        )
        return HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
    }
}

/// One `AgentMTLSClient` per local Home CA so controllers do not rebuild
/// TLS material on every member proxy.
enum HomeDevicesMTLS {
    static func client(dataDir: URL, hostId: String) throws -> AgentMTLSClient {
        try HomeDevicesMTLSCache.shared.client(dataDir: dataDir, hostId: hostId)
    }
}

private final class HomeDevicesMTLSCache: @unchecked Sendable {
    static let shared = HomeDevicesMTLSCache()
    private let lock = NSLock()
    private var cached: (key: String, client: AgentMTLSClient)?

    func client(dataDir: URL, hostId: String) throws -> AgentMTLSClient {
        let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
        let key = "\(dataDir.path)|\(hostId)|\(receipt?.issuedFingerprint ?? "-")"
        lock.lock()
        if let cached, cached.key == key {
            let client = cached.client
            lock.unlock()
            return client
        }
        lock.unlock()
        let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
        let presented = AgentPlaneCertificates.presentationCertificatePEM(
            material: material,
            receipt: receipt,
        )
        let trusts = AgentPlaneCertificates.trustCertificatePEMs(
            material: material,
            receipt: receipt,
        )
        let created = AgentMTLSClient(
            material: material,
            presentationCertificatePEM: presented,
            trustCertificatePEMs: trusts,
        )
        lock.lock()
        self.cached = (key, created)
        lock.unlock()
        return created
    }
}

/// Loopback HTTP client for self-proxy and the agent-plane local forward.
public struct LocalHostProxyClient: HomeDeviceProxyClient {
    public var timeout: TimeInterval
    public var maxBodyBytes: Int

    public init(
        timeout: TimeInterval = 10,
        maxBodyBytes: Int = HomeDeviceProxy.maxBodyBytes,
    ) {
        self.timeout = timeout
        self.maxBodyBytes = maxBodyBytes
    }

    public func send(_ request: HomeDeviceProxyRequest) async throws -> HomeDeviceProxyResponse {
        var outbound = HTTPClientRequest(url: request.url.absoluteString)
        outbound.method = HTTPMethod(rawValue: request.method.uppercased())
        for (name, value) in request.headers {
            outbound.headers.replaceOrAdd(name: name, value: value)
        }
        if let body = request.body {
            outbound.body = .bytes(body)
        }
        let seconds = Int64(max(1, timeout.rounded(.up)))
        let response: HTTPClientResponse
        do {
            response = try await LocalHostProxyHTTP.shared.execute(outbound, timeout: .seconds(seconds))
        } catch {
            throw HomeDeviceProxyError.unreachable(error.localizedDescription)
        }
        let buffer = try await collectProxyBody(response.body, maxBytes: maxBodyBytes)
        let headers = response.headers.map { ($0.name, $0.value) }
        return HomeDeviceProxyResponse(
            status: Int(response.status.code),
            headers: headers,
            body: Data(buffer.readableBytesView),
        )
    }
}

/// Process-wide plaintext loopback client. Never shut down; same lifetime
/// as `AgentMTLSRuntime`. Redirects are off so a 3xx cannot escape loopback.
private enum LocalHostProxyHTTP {
    static let shared: HTTPClient = {
        var config = HTTPClient.Configuration()
        config.redirectConfiguration = .disallow
        config.timeout = HTTPClient.Configuration.Timeout(connect: .seconds(10), read: .seconds(10))
        return HTTPClient(
            eventLoopGroupProvider: .shared(LocalHostProxyHTTPGroup.shared),
            configuration: config,
        )
    }()
}

private enum LocalHostProxyHTTPGroup {
    static let shared = MultiThreadedEventLoopGroup(numberOfThreads: 1)
}

private func collectProxyBody(
    _ body: HTTPClientResponse.Body,
    maxBytes: Int,
) async throws -> ByteBuffer {
    do {
        return try await body.collect(upTo: maxBytes)
    } catch is NIOTooManyBytesError {
        throw HomeDeviceProxyError.responseTooLarge
    } catch let error as HomeDeviceProxyError {
        throw error
    } catch {
        throw HomeDeviceProxyError.unreachable(error.localizedDescription)
    }
}
