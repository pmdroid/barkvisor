import BarkVisorCore
import Foundation
import NIOSSL
import Vapor
import X509

/// Second HTTP listener: required TLS + client cert on the agent port (7778).
///
/// SPA/JWT stays on ``Config.port`` (7777). A bind or cert failure here must
/// not stop the host API or local QEMU children (PAS-47 / PAS-90).
public final class AgentTLSServer: @unchecked Sendable {
    private var app: Vapor.Application?
    private let material: HomeCertificateMaterial
    private let pins: PeerPinStore
    private let hostname: String
    private let port: Int

    public private(set) var boundPort: Int?

    public init(
        material: HomeCertificateMaterial,
        pins: PeerPinStore,
        hostname: String = "0.0.0.0",
        port: Int = Config.agentPort,
    ) {
        self.material = material
        self.pins = pins
        self.hostname = hostname
        self.port = port
    }

    public func start() async throws {
        var env = Environment(name: "production", arguments: ["barkvisor-agent"])
        env.commandInput = CommandInput(arguments: ["barkvisor-agent"])
        let app = try await Vapor.Application.make(env)
        do {
            try configure(app)
            try await app.startup()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        self.app = app
        if let local = app.http.server.shared.localAddress, let bound = local.port {
            self.boundPort = bound
        } else {
            self.boundPort = port
        }
        Log.server.info("BarkVisor agent mTLS listener on port \(boundPort ?? port)")
    }

    public func stop() async {
        guard let app else { return }
        try? await app.asyncShutdown()
        self.app = nil
        self.boundPort = nil
    }

    private func configure(_ app: Vapor.Application) throws {
        let deviceCert = try NIOSSLCertificate(
            bytes: Array(material.deviceCertificatePEM.utf8),
            format: .pem,
        )
        let deviceKey = try NIOSSLPrivateKey(
            bytes: Array(material.deviceKeyPEM.utf8),
            format: .pem,
        )
        let caCert = try NIOSSLCertificate(
            bytes: Array(material.caCertificatePEM.utf8),
            format: .pem,
        )

        var tls = TLSConfiguration.makeServerConfigurationWithMTLS(
            certificateChain: [.certificate(deviceCert)],
            privateKey: .privateKey(deviceKey),
            trustRoots: .certificates([caCert]),
        )
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .noHostnameVerification

        let homeCAPEM = material.caCertificatePEM
        let pinStore = pins

        app.http.server.configuration.hostname = hostname
        app.http.server.configuration.port = port
        app.http.server.configuration.supportVersions = [.one]
        app.http.server.configuration.tlsConfiguration = tls
        app.http.server.configuration.customCertificateVerifyCallbackWithMetadata = { certs, promise in
            AgentTLSServer.verifyClient(
                certs: certs,
                homeCAPEM: homeCAPEM,
                pins: pinStore,
                promise: promise,
            )
        }

        app.middleware.use(StructuredErrorMiddleware())
        app.middleware.use(APIVersionMiddleware(), at: .beginning)
        app.middleware.use(MTLSMiddleware(homeCAPEM: homeCAPEM, pins: pinStore))
        try app.register(collection: AgentMTLSController())
    }

    static func verifyClient(
        certs: [NIOSSLCertificate],
        homeCAPEM: String,
        pins: PeerPinStore,
        promise: EventLoopPromise<NIOSSLVerificationResultWithMetadata>,
    ) {
        guard let leafNIO = certs.first else {
            promise.succeed(.failed)
            return
        }
        let leaf: Certificate
        do {
            leaf = try Certificate(derEncoded: leafNIO.toDERBytes())
        } catch {
            promise.succeed(.failed)
            return
        }
        switch DeviceTrust.evaluate(leaf: leaf, homeCAPEM: homeCAPEM, pins: pins.load()) {
        case .accepted:
            promise.succeed(
                .certificateVerified(VerificationMetadata(NIOSSL.ValidatedCertificateChain(certs))),
            )
        case .rejected:
            promise.succeed(.failed)
        }
    }

    /// Start the agent plane. Returns nil (and logs) on failure so the host
    /// API and local workloads keep running.
    public static func startDetached(
        dataDir: URL,
        hostId: String,
        hostname: String = "0.0.0.0",
        port: Int = Config.agentPort,
    ) async -> AgentTLSServer? {
        if port == Config.port {
            Log.server.error(
                "Agent mTLS port \(port) collides with SPA port; leaving agent listener disabled. Local runtime continues.",
            )
            return nil
        }
        do {
            let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
            let pins = PeerPinStore(dataDir: dataDir)
            let server = AgentTLSServer(
                material: material,
                pins: pins,
                hostname: hostname,
                port: port,
            )
            try await server.start()
            return server
        } catch {
            Log.server.error(
                "Agent mTLS listener not started: \(error.localizedDescription). Local runtime continues on port \(Config.port).",
            )
            return nil
        }
    }
}
