import AsyncHTTPClient
import Foundation
import GRDB
import NIOPosix
import NIOSSL
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("AgentTLSServer", .serialized)
struct AgentTLSServerTests {
    private func isolatedDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-tls-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func `rejects handshake without client cert and accepts home ca cert`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let pins = PeerPinStore(dataDir: dir)
        let server = AgentTLSServer(
            material: material,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)
            #expect(port != Config.port)

            let ca = try NIOSSLCertificate(bytes: Array(material.caCertificatePEM.utf8), format: .pem)
            let deviceCert = try NIOSSLCertificate(
                bytes: Array(material.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let deviceKey = try NIOSSLPrivateKey(
                bytes: Array(material.deviceKeyPEM.utf8),
                format: .pem,
            )

            do {
                _ = try await getWhoami(
                    port: port,
                    trust: ca,
                    clientCert: nil,
                    clientKey: nil,
                )
                Issue.record("handshake without client cert should fail")
            } catch {
                // TLS reject — expected. Do not treat as a server crash.
            }

            let body = try await getWhoami(
                port: port,
                trust: ca,
                clientCert: deviceCert,
                clientKey: deviceKey,
            )
            #expect(body.hostId == hostId)
            #expect(body.trust == "home-ca")
            #expect(body.listener == "mtls")
            #expect(body.fingerprint == material.deviceFingerprint)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `accepts pairwise pinned foreign cert`() async throws {
        let localDir = try isolatedDir()
        let peerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: localDir)
            try? FileManager.default.removeItem(at: peerDir)
        }
        let local = try HomeCAService.loadOrCreate(dataDir: localDir, hostId: UUID().uuidString)
        let peerId = UUID().uuidString
        let peer = try HomeCAService.loadOrCreate(dataDir: peerDir, hostId: peerId)
        let pins = PeerPinStore(dataDir: localDir)
        try pins.pin(hostId: peerId, fingerprint: peer.deviceFingerprint)

        let server = AgentTLSServer(
            material: local,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)

            let ca = try NIOSSLCertificate(bytes: Array(local.caCertificatePEM.utf8), format: .pem)
            let peerCert = try NIOSSLCertificate(
                bytes: Array(peer.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let peerKey = try NIOSSLPrivateKey(bytes: Array(peer.deviceKeyPEM.utf8), format: .pem)
            let body = try await getWhoami(
                port: port,
                trust: ca,
                clientCert: peerCert,
                clientKey: peerKey,
            )
            #expect(body.hostId == peerId)
            #expect(body.trust == "pinned")
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `paired homes verify each other over agent mtls`() async throws {
        let issuerDir = try isolatedDir()
        let joinerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: issuerDir)
            try? FileManager.default.removeItem(at: joinerDir)
        }
        let issuerId = UUID().uuidString
        let joinerId = UUID().uuidString
        let issuer = try HomeCAService.loadOrCreate(dataDir: issuerDir, hostId: issuerId)
        let joiner = try HomeCAService.loadOrCreate(dataDir: joinerDir, hostId: joinerId)
        let csr = try HomeCAService.makeDeviceCSR(hostId: joinerId, keyPEM: joiner.deviceKeyPEM)
        let issued = try HomeCAService.issueDeviceCert(
            hostId: joinerId,
            csrPEM: csr,
            material: issuer,
        )
        let receipt = PairingPeerReceipt(
            peerHostId: issuerId,
            peerFingerprint: issuer.deviceFingerprint,
            caCertificatePEM: issuer.caCertificatePEM,
            caFingerprint: issuer.caFingerprint,
            issuedCertificatePEM: issued.certificatePEM,
            issuedFingerprint: issued.fingerprint,
            pairedAt: "2026-08-14T00:00:00Z",
        )
        try PeerPinStore(dataDir: issuerDir).pin(
            hostId: joinerId,
            fingerprint: joiner.deviceFingerprint,
        )
        try PeerPinStore(dataDir: joinerDir).pin(
            hostId: issuerId,
            fingerprint: issuer.deviceFingerprint,
        )

        let issuerServer = AgentTLSServer(
            material: issuer,
            pins: PeerPinStore(dataDir: issuerDir),
            hostname: "127.0.0.1",
            port: 0,
        )
        let joinerPresented = AgentPlaneCertificates.presentationCertificatePEM(
            material: joiner,
            receipt: receipt,
        )
        let joinerServer = AgentTLSServer(
            material: joiner,
            pins: PeerPinStore(dataDir: joinerDir),
            presentationCertificatePEM: joinerPresented,
            hostname: "127.0.0.1",
            port: 0,
        )
        try await issuerServer.start()
        try await joinerServer.start()
        do {
            let issuerPort = try #require(issuerServer.boundPort)
            let joinerPort = try #require(joinerServer.boundPort)

            // Home still trusts only its own CA — joiner must present the issued leaf.
            let homeClient = AgentMTLSClient(material: issuer)
            let joinerURL = try HomeDeviceProxy.memberURL(
                host: "127.0.0.1",
                port: joinerPort,
                path: "/api/agent/whoami",
            )
            let fromHome = try await homeClient.send(
                HomeDeviceProxyRequest(method: "GET", url: joinerURL),
            )
            #expect((200 ... 299).contains(fromHome.status))

            let joinerClient = AgentMTLSClient(
                material: joiner,
                presentationCertificatePEM: joinerPresented,
                trustCertificatePEMs: AgentPlaneCertificates.trustCertificatePEMs(
                    material: joiner,
                    receipt: receipt,
                ),
            )
            let issuerURL = try HomeDeviceProxy.memberURL(
                host: "127.0.0.1",
                port: issuerPort,
                path: "/api/agent/whoami",
            )
            let fromJoiner = try await joinerClient.send(
                HomeDeviceProxyRequest(method: "GET", url: issuerURL),
            )
            #expect((200 ... 299).contains(fromJoiner.status))
            await issuerServer.stop()
            await joinerServer.stop()
        } catch {
            await issuerServer.stop()
            await joinerServer.stop()
            throw error
        }
    }

    @Test func `streams Library image bytes on the agent plane`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let material = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let pins = PeerPinStore(dataDir: dir)

        let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
        try AppDatabase.makeMigrator().migrate(pool)
        let payload = Data("agent-plane-bytes".utf8)
        let file = dir.appendingPathComponent("cloud.img")
        try payload.write(to: file)
        let digest = try ImageFileChecksum.sha256Hex(ofFile: file)
        let now = "2026-01-01T00:00:00Z"
        try await pool.write { db in
            try VMImage(
                id: "img-stream", name: "Cloud", imageType: "cloud-image", arch: "arm64",
                path: file.path, sizeBytes: Int64(payload.count), status: "ready", error: nil,
                sourceUrl: "https://example.com/cloud.img", sha256: digest,
                createdAt: now, updatedAt: now,
            ).insert(db)
        }

        let server = AgentTLSServer(
            material: material,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
            database: pool,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)
            let client = AgentMTLSClient(material: material, timeoutSeconds: 5)
            let listURL = try HomeDeviceProxy.memberURL(
                host: "127.0.0.1",
                port: port,
                path: LibraryDepotHTTP.listPath,
                query: "sourceUrl=https://example.com/cloud.img",
            )
            let listed = try await client.send(HomeDeviceProxyRequest(method: "GET", url: listURL))
            #expect((200 ... 299).contains(listed.status))
            let infos = try JSONDecoder().decode([LibraryDepotImageInfo].self, from: listed.body)
            #expect(infos.count == 1)
            #expect(infos[0].id == "img-stream")
            #expect(infos[0].sha256 == digest)

            let dest = dir.appendingPathComponent("copied.img")
            let contentURL = try HomeDeviceProxy.memberURL(
                host: "127.0.0.1",
                port: port,
                path: LibraryDepotHTTP.contentPath(id: "img-stream"),
            )
            let streamed = try await client.streamGet(url: contentURL, to: dest)
            #expect(streamed.status == 200)
            #expect(streamed.sha256 == digest)
            #expect(try Data(contentsOf: dest) == payload)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `reloadFromDisk presents reminted device certificate`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let pins = PeerPinStore(dataDir: dir)
        let server = AgentTLSServer(
            material: first,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        do {
            let port = try #require(server.boundPort)
            try await server.reloadFromDisk(now: now)
            let reloaded = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)
            #expect(reloaded.deviceFingerprint != first.deviceFingerprint)
            #expect(reloaded.caFingerprint == first.caFingerprint)

            let ca = try NIOSSLCertificate(
                bytes: Array(reloaded.caCertificatePEM.utf8),
                format: .pem,
            )
            let deviceCert = try NIOSSLCertificate(
                bytes: Array(reloaded.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let deviceKey = try NIOSSLPrivateKey(
                bytes: Array(reloaded.deviceKeyPEM.utf8),
                format: .pem,
            )
            let body = try await getWhoami(
                port: port,
                trust: ca,
                clientCert: deviceCert,
                clientKey: deviceKey,
            )
            #expect(body.hostId == hostId)
            #expect(body.fingerprint == reloaded.deviceFingerprint)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `reloadFromDisk restore bind keeps previous listener`() async throws {
        let dir = try isolatedDir()
        let peerDir = try isolatedDir()
        defer {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.removeItem(at: peerDir)
        }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        // First device leaf is already expired (that's why remint fires). Handshake
        // with a still-valid pinned peer so DeviceTrust does not reject expiry.
        let peerId = UUID().uuidString
        let peer = try HomeCAService.loadOrCreate(dataDir: peerDir, hostId: peerId)
        let pins = PeerPinStore(dataDir: dir)
        try pins.pin(hostId: peerId, fingerprint: peer.deviceFingerprint)
        let server = AgentTLSServer(
            material: first,
            pins: pins,
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        do {
            _ = try #require(server.boundPort)
            server.testStartListenerFailuresRemaining = 1
            do {
                try await server.reloadFromDisk(now: now)
                Issue.record("remint bind should fail")
            } catch {
                // Remint bind failed; restore should have rebound previous material.
            }
            #expect(server.testStartListenerFailuresRemaining == 0)
            let rebound = try #require(server.boundPort)

            let ca = try NIOSSLCertificate(bytes: Array(first.caCertificatePEM.utf8), format: .pem)
            let peerCert = try NIOSSLCertificate(
                bytes: Array(peer.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let peerKey = try NIOSSLPrivateKey(
                bytes: Array(peer.deviceKeyPEM.utf8),
                format: .pem,
            )
            let body = try await getWhoami(
                port: rebound,
                trust: ca,
                clientCert: peerCert,
                clientKey: peerKey,
            )
            #expect(body.hostId == peerId)
            #expect(body.trust == "pinned")
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `reloadFromDisk recovers after remint and restore bind fail`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let server = AgentTLSServer(
            material: first,
            pins: PeerPinStore(dataDir: dir),
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        do {
            server.testStartListenerFailuresRemaining = 2
            do {
                try await server.reloadFromDisk(now: now)
                Issue.record("reload should fail when remint and restore cannot bind")
            } catch {
                // Both binds failed — listener must stay down, not silently swallow.
            }
            #expect(server.testStartListenerFailuresRemaining == 0)
            #expect(server.boundPort == nil)

            // Next reload (hourly loop) must bring the plane back without a restart.
            try await server.reloadFromDisk(now: now)
            let port = try #require(server.boundPort)
            let reloaded = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: now)
            #expect(reloaded.deviceFingerprint != first.deviceFingerprint)

            let ca = try NIOSSLCertificate(
                bytes: Array(reloaded.caCertificatePEM.utf8),
                format: .pem,
            )
            let deviceCert = try NIOSSLCertificate(
                bytes: Array(reloaded.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let deviceKey = try NIOSSLPrivateKey(
                bytes: Array(reloaded.deviceKeyPEM.utf8),
                format: .pem,
            )
            let body = try await getWhoami(
                port: port,
                trust: ca,
                clientCert: deviceCert,
                clientKey: deviceKey,
            )
            #expect(body.hostId == hostId)
            #expect(body.fingerprint == reloaded.deviceFingerprint)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `reloadFromDisk rebinds when listener is already down`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let server = AgentTLSServer(
            material: first,
            pins: PeerPinStore(dataDir: dir),
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        do {
            await server.shutdownListener()
            #expect(server.boundPort == nil)

            try await server.reloadFromDisk()
            let port = try #require(server.boundPort)

            let ca = try NIOSSLCertificate(bytes: Array(first.caCertificatePEM.utf8), format: .pem)
            let deviceCert = try NIOSSLCertificate(
                bytes: Array(first.deviceCertificatePEM.utf8),
                format: .pem,
            )
            let deviceKey = try NIOSSLPrivateKey(
                bytes: Array(first.deviceKeyPEM.utf8),
                format: .pem,
            )
            let body = try await getWhoami(
                port: port,
                trust: ca,
                clientCert: deviceCert,
                clientKey: deviceKey,
            )
            #expect(body.hostId == hostId)
            #expect(body.fingerprint == first.deviceFingerprint)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }

    @Test func `stop prevents reloadFromDisk from restarting the listener`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId)
        let server = AgentTLSServer(
            material: first,
            pins: PeerPinStore(dataDir: dir),
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        await server.stop()
        #expect(server.boundPort == nil)

        try await server.reloadFromDisk()
        #expect(server.boundPort == nil)
    }

    @Test func `overlapping stop and reload leaves the listener down`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let now = Date()
        let createdAt = now.addingTimeInterval(-(HomeCAService.deviceValidity + 3_600))
        let first = try HomeCAService.loadOrCreate(dataDir: dir, hostId: hostId, now: createdAt)
        let server = AgentTLSServer(
            material: first,
            pins: PeerPinStore(dataDir: dir),
            hostname: "127.0.0.1",
            port: 0,
            dataDir: dir,
            hostId: hostId,
        )
        try await server.start()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await server.reloadFromDisk(now: now)
            }
            group.addTask {
                await server.stop()
            }
        }
        #expect(server.boundPort == nil)
        try await server.reloadFromDisk(now: now)
        #expect(server.boundPort == nil)
    }

    @Test func `startDetached failure leaves local runtime independent`() async throws {
        let dir = try isolatedDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let hostId = UUID().uuidString
        let first = await AgentTLSServer.startDetached(
            dataDir: dir,
            hostId: hostId,
            hostname: "127.0.0.1",
            port: 0,
        )
        let running = try #require(first)
        do {
            // Same port is already bound — startDetached must swallow the error.
            let bound = try #require(running.boundPort)
            let second = await AgentTLSServer.startDetached(
                dataDir: dir,
                hostId: hostId,
                hostname: "127.0.0.1",
                port: bound,
            )
            #expect(second == nil)

            // Colliding with the SPA port is also non-fatal.
            let collided = await AgentTLSServer.startDetached(
                dataDir: dir,
                hostId: hostId,
                hostname: "127.0.0.1",
                port: Config.port,
            )
            #expect(collided == nil)
            await running.stop()
        } catch {
            await running.stop()
            throw error
        }
    }

    private func getWhoami(
        port: Int,
        trust: NIOSSLCertificate,
        clientCert: NIOSSLCertificate?,
        clientKey: NIOSSLPrivateKey?,
    ) async throws -> AgentPeerIdentity {
        var tls = TLSConfiguration.makeClientConfiguration()
        // Network.framework (AHC default on macOS) rejects .noHostnameVerification.
        tls.certificateVerification = .none
        tls.trustRoots = .certificates([trust])
        if let clientCert, let clientKey {
            tls.certificateChain = [.certificate(clientCert)]
            tls.privateKey = .privateKey(clientKey)
        }
        var config = HTTPClient.Configuration()
        config.tlsConfiguration = tls
        // Client certs require NIO/BSD sockets; Network.framework rejects them.
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: config)
        do {
            var request = HTTPClientRequest(url: "https://127.0.0.1:\(port)/api/agent/whoami")
            request.method = .GET
            let response = try await client.execute(request, timeout: .seconds(5))
            let buffer = try await response.body.collect(upTo: 1_048_576)
            let decoded = try JSONDecoder().decode(
                AgentPeerIdentity.self,
                from: Data(buffer.readableBytesView),
            )
            try await client.shutdown()
            try await group.shutdownGracefully()
            return decoded
        } catch {
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            throw error
        }
    }
}
