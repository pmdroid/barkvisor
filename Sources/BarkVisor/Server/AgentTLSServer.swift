import BarkVisorCore
import Foundation
import GRDB
import NIOSSL
import Vapor
import X509

/// Second HTTP listener: required TLS + client cert on the agent port (7778).
///
/// SPA/JWT stays on ``Config.port`` (7777). A bind or cert failure here must
/// not stop the host API or local QEMU children (PAS-47 / PAS-90).
///
/// `trustRoots` lists this Device's Home CA so NIO can build an mTLS context.
/// Client authentication is decided only in
/// ``customCertificateVerifyCallbackWithMetadata`` via ``DeviceTrust``
/// (Home CA **or** pairwise pin). Pins are not added to `trustRoots` and
/// must not be — that would weaken pin binding. Pins-only peers are accepted
/// in the callback; they do not need to chain to `trustRoots`.
public final class AgentTLSServer: @unchecked Sendable {
    public static let certificateReloadInterval: TimeInterval = 60 * 60

    private var app: Vapor.Application?
    private var material: HomeCertificateMaterial
    private var presentationCertificatePEM: String
    private let pins: PeerPinStore
    private let hostname: String
    private var listenPort: Int
    private let database: DatabasePool?
    private let dataDir: URL?
    private let hostId: String?
    private let vmState: (any VMStateQuerying)?
    private let consoleBuffers: ConsoleBufferManager?
    private var reloadTask: Task<Void, Never>?

    public private(set) var boundPort: Int?

    public init(
        material: HomeCertificateMaterial,
        pins: PeerPinStore,
        presentationCertificatePEM: String? = nil,
        hostname: String = "0.0.0.0",
        port: Int = Config.agentPort,
        dataDir: URL? = nil,
        hostId: String? = nil,
        database: DatabasePool? = nil,
        vmState: (any VMStateQuerying)? = nil,
        consoleBuffers: ConsoleBufferManager? = nil,
    ) {
        self.material = material
        self.presentationCertificatePEM = presentationCertificatePEM ?? material.deviceCertificatePEM
        self.pins = pins
        self.hostname = hostname
        self.listenPort = port
        self.dataDir = dataDir
        self.hostId = hostId
        self.database = database
        self.vmState = vmState
        self.consoleBuffers = consoleBuffers
    }

    public func start() async throws {
        try await startListener()
        startReloadLoopIfNeeded()
    }

    public func stop() async {
        reloadTask?.cancel()
        reloadTask = nil
        await shutdownListener()
    }

    /// Test seam: next N `startListener` calls throw before binding.
    var testStartListenerFailuresRemaining = 0

    /// Re-read Home CA / Device leaf (and pairing receipt) and rebind if they changed.
    ///
    /// If the listener is already down, this always attempts to bind — even when
    /// on-disk certs match in-memory material — so a failed remint/restore does
    /// not leave the agent plane offline until process restart.
    public func reloadFromDisk(now: Date = Date()) async throws {
        guard let dataDir, let hostId else { return }
        let fresh = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId, now: now)
        let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
        let presented = AgentPlaneCertificates.presentationCertificatePEM(
            material: fresh,
            receipt: receipt,
        )
        let certsUnchanged = fresh.deviceCertificatePEM == material.deviceCertificatePEM
            && fresh.caCertificatePEM == material.caCertificatePEM
            && presented == presentationCertificatePEM
        if certsUnchanged {
            try await ensureListenerRunning()
            return
        }

        // Parse reminted PEMs before dropping the live listener so a corrupt
        // rotation cannot take the agent plane down by itself.
        do {
            _ = try Self.parseTLSIdentity(
                material: fresh,
                presentationCertificatePEM: presented,
            )
        } catch {
            Log.server.error(
                "Agent mTLS reload rejected unusable reminted certs: \(error.localizedDescription). Keeping current listener.",
            )
            throw error
        }

        let previousMaterial = material
        let previousPresented = presentationCertificatePEM
        await shutdownListener()
        material = fresh
        presentationCertificatePEM = presented
        do {
            try await startListener()
        } catch let remintError {
            Log.server.error(
                "Agent mTLS listener failed to bind reminted certs: \(remintError.localizedDescription). Restoring previous material.",
            )
            material = previousMaterial
            presentationCertificatePEM = previousPresented
            do {
                try await startListener()
            } catch let restoreError {
                Log.server.error(
                    """
                    Agent mTLS listener restore failed: \(restoreError.localizedDescription). \
                    Agent plane is offline until the next successful reload. Local runtime continues.
                    """,
                )
            }
            throw remintError
        }
    }

    private func ensureListenerRunning() async throws {
        guard app == nil else { return }
        do {
            try await startListener()
        } catch {
            Log.server.error(
                "Agent mTLS listener still down after reload: \(error.localizedDescription). Local runtime continues.",
            )
            throw error
        }
    }

    private func startListener() async throws {
        if testStartListenerFailuresRemaining > 0 {
            testStartListenerFailuresRemaining -= 1
            throw AgentTLSBindError.testForcedFailure
        }
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
            listenPort = bound
        } else {
            self.boundPort = listenPort
        }
        Log.server.info("BarkVisor agent mTLS listener on port \(boundPort ?? listenPort)")
    }

    func shutdownListener() async {
        guard let app else { return }
        try? await app.asyncShutdown()
        self.app = nil
        self.boundPort = nil
    }

    private func startReloadLoopIfNeeded() {
        guard dataDir != nil, hostId != nil, reloadTask == nil else { return }
        reloadTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(Self.certificateReloadInterval))
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                do {
                    try await self?.reloadFromDisk()
                } catch {
                    Log.server.error(
                        "Agent mTLS certificate reload failed: \(error.localizedDescription). Will retry on the next interval.",
                    )
                }
            }
        }
    }

    private struct TLSIdentity {
        let deviceCert: NIOSSLCertificate
        let deviceKey: NIOSSLPrivateKey
        let caCert: NIOSSLCertificate
    }

    private static func parseTLSIdentity(
        material: HomeCertificateMaterial,
        presentationCertificatePEM: String,
    ) throws -> TLSIdentity {
        let deviceCert = try NIOSSLCertificate(
            bytes: Array(presentationCertificatePEM.utf8),
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
        return TLSIdentity(deviceCert: deviceCert, deviceKey: deviceKey, caCert: caCert)
    }

    private func configure(_ app: Vapor.Application) throws {
        let identity = try Self.parseTLSIdentity(
            material: material,
            presentationCertificatePEM: presentationCertificatePEM,
        )
        let deviceCert = identity.deviceCert
        let deviceKey = identity.deviceKey
        let caCert = identity.caCert

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
        app.http.server.configuration.port = listenPort
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
        let localProxy = AgentLocalProxyController(vmState: vmState, consoleBuffers: consoleBuffers)
        try app.register(collection: localProxy)
        localProxy.registerConsoleTunnels(app: app)
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
        let loadedPins: [PeerPin]
        do {
            loadedPins = try pins.load()
        } catch {
            Log.server.error("Peer pin store is corrupt: \(error.localizedDescription)")
            promise.succeed(.failed)
            return
        }
        switch DeviceTrust.evaluate(leaf: leaf, homeCAPEM: homeCAPEM, pins: loadedPins) {
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
        database: DatabasePool? = nil,
        vmState: (any VMStateQuerying)? = nil,
        consoleBuffers: ConsoleBufferManager? = nil,
    ) async -> AgentTLSServer? {
        if port != 0, Config.port != 0, port == Config.port {
            Log.server.error(
                "Agent mTLS port \(port) collides with SPA port; leaving agent listener disabled. Local runtime continues.",
            )
            return nil
        }
        do {
            let material = try HomeCAService.loadOrCreate(dataDir: dataDir, hostId: hostId)
            let pins = PeerPinStore(dataDir: dataDir)
            _ = try pins.load()
            let receipt = try? PairingService.loadReceipt(dataDir: dataDir)
            let presented = AgentPlaneCertificates.presentationCertificatePEM(
                material: material,
                receipt: receipt,
            )
            let server = AgentTLSServer(
                material: material,
                pins: pins,
                presentationCertificatePEM: presented,
                hostname: hostname,
                port: port,
                dataDir: dataDir,
                hostId: hostId,
                database: database,
                vmState: vmState,
                consoleBuffers: consoleBuffers,
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

private enum AgentTLSBindError: Error, LocalizedError {
    case testForcedFailure

    var errorDescription: String? {
        switch self {
        case .testForcedFailure:
            "forced test bind failure"
        }
    }
}
