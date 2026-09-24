import Foundation
import Testing
@testable import BarkVisorCore
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct LocalManagementBoundaryTests {
    private let peer = LocalPeerIdentity(uid: 1_000, gid: 1_000, pid: 20)

    @Test func `roles publish listeners and privilege`() {
        let daemon = ListenerPlan.forRole(.barkDaemon)
        #expect(daemon.managementListen)
        #expect(!daemon.publicHTTP)
        #expect(!daemon.deviceTLS)
        #expect(!daemon.tcpManagement)
        let server = ListenerPlan.forRole(.barkServer)
        #expect(server.publicHTTP)
        #expect(server.deviceTLS)
        #expect(!server.managementListen)
        #expect(!server.tcpManagement)
        #expect(!ListenerPlan.forRole(.combined).tcpManagement)
        #expect(PrivilegeBoundary.forRole(.barkServer).serverIsUnprivileged)
        #expect(PrivilegeBoundary.forRole(.barkDaemon).canOpenDockerSocket)
        #expect(!PrivilegeBoundary.forRole(.barkServer).canWriteAuthoritativeState)
    }

    @Test func `appliance daemon allows only the server uid`() {
        #expect(LocalManagementPeers.allowlist(daemonEUID: 0, serverUID: 1_000) == [1_000])
        #expect(LocalManagementPeers.allowlist(daemonEUID: 0, serverUID: 0).isEmpty)
        #expect(LocalManagementPeers.allowlist(daemonEUID: 0, serverUID: nil).isEmpty)
        #expect(LocalManagementPeers.allowlist(daemonEUID: 1_000, serverUID: nil) == [1_000])
        let root = SocketPermissionPlan.forDaemonEUID(0)
        #expect(root.directoryMode == 0o750)
        #expect(root.socketMode == 0o660)
        let dev = SocketPermissionPlan.forDaemonEUID(1_000)
        #expect(dev.directoryMode == 0o700)
        #expect(dev.socketMode == 0o600)
        let socket = ManagementSocketPath.path(socketDir: URL(fileURLWithPath: "/var/run/barkvisor"))
        #expect(socket == "/var/run/barkvisor/management/barkvisor.sock")
    }

    @Test func `bark server cannot open the authoritative database`() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("bv-db-\(UUID().uuidString).sqlite").path
        #expect(throws: ServiceProcessRoleError.serverCannotOpenAuthoritativeState) {
            _ = try AppDatabase(path: path, role: .barkServer)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(throws: ServiceProcessRoleError.serverRefusesRoot) {
            try BarkServerStartup.refuseRoot(euid: 0)
        }
        try BarkServerStartup.refuseRoot(euid: 1_000)
    }

    @Test func `forged revoked and foreign peers are rejected before an effect`() async {
        let session = LocalManagementSession(policy: samplePolicy())
        let forged = await session.handle(
            peer: peer,
            request: request(name: "applyMarker", claim: "admin", token: nil, operation: "op-forge"),
        )
        #expect(forged.rejection == LocalRejection.forgedIdentity.rawValue)
        let revoked = await session.handle(
            peer: peer,
            request: request(name: "applyMarker", token: "token-revoked", operation: "op-revoked"),
        )
        #expect(revoked.rejection == LocalRejection.revokedMember.rawValue)
        let stranger = await session.handle(
            peer: LocalPeerIdentity(uid: 4, gid: 4, pid: 1),
            request: request(name: "applyMarker", token: "token-a", operation: "op-stranger"),
        )
        #expect(stranger.rejection == LocalRejection.peerNotAllowed.rawValue)
        let mismatched = await session.handle(
            peer: peer,
            request: request(
                name: "applyMarker",
                claim: "admin",
                token: "token-a",
                operation: "op-mismatch",
            ),
        )
        #expect(mismatched.rejection == LocalRejection.forgedIdentity.rawValue)
        #expect(await session.effectCount() == 0)
    }

    @Test func `resources terminal and protocol version stay bounded`() async {
        let session = LocalManagementSession(policy: samplePolicy())
        let outside = await session.handle(
            peer: peer,
            request: request(
                name: "applyMarker",
                token: "token-a",
                operation: "op-path",
                paths: ["/var/lib/barkvisor-evil/db"],
            ),
        )
        #expect(outside.rejection == LocalRejection.invalidPath.rawValue)
        let dotted = await session.handle(
            peer: peer,
            request: request(
                name: "applyMarker",
                token: "token-a",
                operation: "op-dot",
                paths: ["/var/lib/barkvisor/../../etc/passwd"],
            ),
        )
        #expect(dotted.rejection == LocalRejection.invalidPath.rawValue)
        let mount = await session.handle(
            peer: peer,
            request: request(
                name: "applyMarker",
                token: "token-a",
                operation: "op-mount",
                mounts: ["/"],
            ),
        )
        #expect(mount.rejection == LocalRejection.unauthorizedMount.rawValue)
        let device = await session.handle(
            peer: peer,
            request: request(
                name: "applyMarker",
                token: "token-a",
                operation: "op-dev",
                devices: ["/dev/sda"],
            ),
        )
        #expect(device.rejection == LocalRejection.unauthorizedDevice.rawValue)
        let rootTerminal = await session.handle(
            peer: peer,
            request: request(
                name: "openTerminal",
                token: "token-a",
                operation: "op-term",
                terminalUID: 0,
            ),
        )
        #expect(rootTerminal.rejection == LocalRejection.terminalRootRejected.rawValue)
        let old = await session.handle(
            peer: peer,
            request: request(name: "applyMarker", token: "token-a", operation: "op-ver", version: 0),
        )
        #expect(old.rejection == LocalRejection.unsupportedProtocol.rawValue)
        let shell = await session.handle(
            peer: peer,
            request: request(name: "shell", token: "token-a", operation: "op-shell"),
        )
        #expect(shell.rejection == LocalRejection.unknownOperation.rawValue)
        #expect(await session.effectCount() == 0)
        let version = await session.handle(
            peer: peer,
            request: request(name: "protocolVersion", operation: "startup"),
        )
        #expect(version.accepted)
        #expect(version.marker == "1")
        #expect(await session.effectCount() == 0)
    }

    @Test func `accepted work survives a repeated submit and a lost reply`() async {
        let session = LocalManagementSession(policy: samplePolicy())
        let first = await session.handle(peer: peer, request: marker("op-1", "once"))
        let second = await session.handle(peer: peer, request: marker("op-1", "twice"))
        #expect(first.accepted)
        #expect(first.subject == "device-a")
        #expect(second.marker == "once")
        #expect(await session.effectCount() == 1)
        let hidden = await session.handle(
            peer: peer,
            request: request(name: "query", token: "token-revoked", operation: "op-1"),
        )
        #expect(hidden.rejection == LocalRejection.revokedMember.rawValue)
        let seen = await session.handle(
            peer: peer,
            request: request(name: "query", token: "token-a", operation: "op-1"),
        )
        #expect(seen.marker == "once")
        #expect(await session.effectCount() == 1)
    }

    @Test func `a lost reply queries the operation before another submit`() throws {
        var names: [String] = []
        let resumed = try LocalManagementClient.submit(marker("op-9", "kept")) { request in
            names.append(request.name)
            if request.name == "applyMarker" {
                throw LocalManagementError.connectionLost
            }
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: true,
                phase: "completed",
                effectCount: 1,
                marker: "kept",
            )
        }
        #expect(names == ["applyMarker", "query"])
        #expect(resumed.phase == "completed")
        #expect(resumed.marker == "kept")

        var absent: [String] = []
        let created = try LocalManagementClient.submit(marker("op-missing", "new")) { request in
            absent.append(request.name)
            if request.name == "query" {
                return LocalManagementResponse(
                    requestId: request.requestId,
                    operationId: request.operationId,
                    accepted: false,
                    phase: "absent",
                    effectCount: 0,
                )
            }
            if absent.count(where: { $0 == "applyMarker" }) == 1 {
                throw LocalManagementError.connectionLost
            }
            return LocalManagementResponse(
                requestId: request.requestId,
                operationId: request.operationId,
                accepted: true,
                phase: "completed",
                effectCount: 1,
                marker: "new",
            )
        }
        #expect(absent == ["applyMarker", "query", "applyMarker"])
        #expect(created.marker == "new")
    }

    @Test func `slow consumers and oversized frames are bounded`() async throws {
        let session = LocalManagementSession(policy: samplePolicy(maxEventBytes: 100))
        #expect(await session.noteEvent(bytes: 40) == nil)
        #expect(await session.noteEvent(bytes: 70) == .slowConsumer)
        #expect(await session.bufferedEvents() == 40)
        var huge = Data([0, 0x10, 0, 1])
        #expect(throws: LocalManagementError.payloadTooLarge) {
            _ = try LocalManagementFraming.payloadLength(prefix: huge)
        }
        let request = marker("op-frame", "body")
        let framed = try LocalManagementFraming.encode(request)
        let length = try LocalManagementFraming.payloadLength(prefix: framed.prefix(4))
        let decoded = try LocalManagementFraming.decodeRequest(framed.dropFirst(4))
        #expect(length == framed.count - 4)
        #expect(decoded.marker == "body")
        _ = huge
    }

    @Test func `kvm follows the workload identity on each install`() {
        let node = DeviceNodeFacts(uid: 0, gid: 66, mode: 0o660)
        #expect(!WorkloadDeviceAccess.canOpen(workloadUID: 1_000, workloadGIDs: [1_000], node: node))
        #expect(WorkloadDeviceAccess.canOpen(workloadUID: 1_000, workloadGIDs: [66], node: node))
        #expect(!WorkloadDeviceAccess.canOpen(workloadUID: 1_000, workloadGIDs: [66], node: nil))
        let blocked = WorkloadDeviceAccess.report(
            platform: "Linux",
            dataDir: "/home/dev/.local/share/barkvisor",
            deviceNodeExists: true,
            workloadCanOpen: false,
        )
        #expect(blocked.accelerator == "tcg")
        #expect(blocked.install == "development")
        #expect(blocked.deviceNodeExists)
        let appliance = WorkloadDeviceAccess.report(
            platform: "Linux",
            dataDir: WorkloadDeviceAccess.applianceDataDir,
            deviceNodeExists: true,
            workloadCanOpen: true,
        )
        #expect(appliance.accelerator == "kvm")
        #expect(appliance.install == "appliance")
        let mac = WorkloadDeviceAccess.report(
            platform: "macOS",
            dataDir: "/tmp/barkvisor",
            deviceNodeExists: false,
            workloadCanOpen: false,
        )
        #expect(mac.accelerator == "hvf")
        #expect(mac.install == "development")
        let identity = WorkloadDeviceAccess.workloadIdentity(
            euid: 0,
            dropsOnPlatform: true,
            lookup: { name in
                name == "barkvisor" ? (uid: 1_000, groups: [66]) : nil
            },
            currentGroups: [0],
        )
        #expect(identity.uid == 1_000)
        #expect(identity.groups == [66])
        let inherited = WorkloadDeviceAccess.workloadIdentity(
            euid: 0,
            dropsOnPlatform: true,
            lookup: { _ in nil },
            currentGroups: [0],
        )
        #expect(inherited.uid == 0)
    }

    @Test func `packaged units keep the appliance service and split identities`() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appliance = try String(
            contentsOf: root.appendingPathComponent("packaging/linux/barkvisor.service"),
            encoding: .utf8,
        )
        #expect(appliance.contains("ExecStart=/usr/local/bin/barkvisor\n"))
        #expect(appliance.contains("User=root"))
        for relative in [
            "packaging/linux/barkvisor-daemon.service",
            "Resources/barkvisor-daemon.service",
        ] {
            let unit = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(unit.contains("User=root"))
            #expect(unit.contains("ExecStart=/usr/local/bin/barkvisor daemon"))
            #expect(unit.contains("BARKVISOR_PROCESS_ROLE=bark-daemon"))
            #expect(!unit.contains("BARKVISOR_PORT"))
            #expect(unit.contains("KillMode=process"))
            #expect(unit.contains("-/var/run/docker.sock"))
            #expect(unit.contains("RuntimeDirectoryMode=0770"))
        }
        for relative in [
            "packaging/linux/barkvisor-server.service",
            "Resources/barkvisor-server.service",
        ] {
            let unit = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
            #expect(unit.contains("User=barkvisor"))
            #expect(!unit.contains("User=root"))
            #expect(unit.contains("ExecStart=/usr/local/bin/barkvisor server"))
            #expect(unit.contains("NoNewPrivileges=true"))
            #expect(unit.contains("PrivateDevices=true"))
            #expect(unit.contains("InaccessiblePaths=-/run/docker.sock -/var/run/docker.sock -/dev/kvm"))
            #expect(!unit.contains("ReadWritePaths"))
            #expect(!unit.contains("SupplementaryGroups"))
            #expect(!unit.contains("BARKVISOR_PORT"))
            #expect(unit.contains("Requires=barkvisor-daemon.service"))
        }
        let daemonPlist = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/homebrew/homebrew.mxcl.barkvisor-daemon.plist",
            ),
            encoding: .utf8,
        )
        let serverPlist = try String(
            contentsOf: root.appendingPathComponent(
                "packaging/homebrew/homebrew.mxcl.barkvisor-server.plist",
            ),
            encoding: .utf8,
        )
        #expect(daemonPlist.contains("<string>daemon</string>"))
        #expect(daemonPlist.contains("AbandonProcessGroup"))
        #expect(!daemonPlist.contains("<key>UserName</key>"))
        #expect(serverPlist.contains("<key>UserName</key>"))
        #expect(serverPlist.contains("<string>barkvisor</string>"))
        #expect(serverPlist.contains("<string>server</string>"))
        #expect(!serverPlist.contains("docker.sock"))
    }

    #if !os(Windows)
        @Test func `unix socket enforces the peer and keeps the operation`() async throws {
            let uid = WorkloadPrivilegeDrop.currentEUID()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("bv-\(UUID().uuidString.prefix(8))", isDirectory: true)
            let path = directory.appendingPathComponent("s").path
            let session = LocalManagementSession(policy: samplePolicy(uid: uid))
            let permissions = SocketPermissionPlan.forDaemonEUID(uid)
            let server = LocalManagementSocketServer(
                path: path,
                session: session,
                directoryMode: permissions.directoryMode,
                socketMode: permissions.socketMode,
            )
            let task = Task { try await server.run() }
            do {
                for _ in 0 ..< 50 {
                    if FileManager.default.fileExists(atPath: path) { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(FileManager.default.fileExists(atPath: path))
                #expect(!server.bindsTCP)
                #expect(server.boundUnixPath == path)
                let socketMode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
                let directoryMode = try FileManager.default.attributesOfItem(
                    atPath: directory.path,
                )[.posixPermissions] as? NSNumber
                #expect(socketMode?.uint16Value == permissions.socketMode)
                #expect(directoryMode?.uint16Value == permissions.directoryMode)
                let applied = try LocalManagementSocketClient.exchange(
                    path: path,
                    request: marker("sock-1", "kept", token: "token-a"),
                )
                let again = try LocalManagementSocketClient.exchange(
                    path: path,
                    request: marker("sock-1", "other", token: "token-a"),
                )
                #expect(applied.marker == "kept")
                #expect(again.marker == "kept")
                #expect(await session.effectCount() == 1)
                let forged = try LocalManagementSocketClient.exchange(
                    path: path,
                    request: request(
                        name: "applyMarker",
                        claim: "root",
                        token: nil,
                        operation: "sock-forged",
                    ),
                )
                #expect(forged.rejection == LocalRejection.forgedIdentity.rawValue)
                let raw = try rawExchange(path: path, payload: Data([0x7F, 0xFF, 0xFF, 0xFF]))
                #expect(raw.rejection == LocalRejection.payloadTooLarge.rawValue)
                let broken = try rawExchange(path: path, payload: framed(Data("{".utf8)))
                #expect(broken.rejection == LocalRejection.malformed.rawValue)
                #expect(await session.effectCount() == 1)
                server.stop()
                _ = try await task.value
            } catch {
                server.stop()
                _ = try? await task.value
                throw error
            }
        }
    #endif

    private func samplePolicy(
        uid: UInt32 = 1_000,
        maxEventBytes: Int = LocalManagementLimits.maxEventBytes,
    ) -> LocalManagementPolicy {
        LocalManagementPolicy(
            allowedPeerUIDs: [uid],
            memberships: [
                MembershipFact(subject: "device-a", sessionToken: "token-a", revoked: false),
                MembershipFact(subject: "device-b", sessionToken: "token-revoked", revoked: true),
            ],
            resources: ResourcePolicy(
                allowedRoots: ["/var/lib/barkvisor"],
                allowedMounts: ["/srv/vol"],
                allowedDevices: ["/dev/net/tun"],
            ),
            maxEventBytes: maxEventBytes,
        )
    }

    private func request(
        name: String,
        claim: String? = nil,
        token: String? = nil,
        operation: String,
        version: Int = LocalManagementLimits.version,
        paths: [String] = [],
        mounts: [String] = [],
        devices: [String] = [],
        terminalUID: UInt32? = nil,
    ) -> LocalManagementRequest {
        LocalManagementRequest(
            version: version,
            requestId: "req-\(operation)",
            operationId: operation,
            name: name,
            claimedUserId: claim,
            sessionToken: token,
            paths: paths,
            mounts: mounts,
            devices: devices,
            terminalUID: terminalUID,
        )
    }

    private func marker(
        _ operation: String,
        _ marker: String,
        token: String = "token-a",
    ) -> LocalManagementRequest {
        LocalManagementRequest(
            requestId: "req-\(operation)",
            operationId: operation,
            name: "applyMarker",
            sessionToken: token,
            marker: marker,
        )
    }
}

#if !os(Windows)
    private func framed(_ payload: Data) -> Data {
        var data = Data()
        let count = UInt32(payload.count)
        data.append(UInt8((count >> 24) & 0xFF))
        data.append(UInt8((count >> 16) & 0xFF))
        data.append(UInt8((count >> 8) & 0xFF))
        data.append(UInt8(count & 0xFF))
        data.append(payload)
        return data
    }

    private func rawExchange(path: String, payload: Data) throws -> LocalManagementResponse {
        let fd = socket(PlatformSocket.unixFamily, PlatformSocket.stream, 0)
        guard fd >= 0 else { throw LocalManagementError.connectionLost }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(PlatformSocket.unixFamily)
        let bytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: bytes.count) { dest in
                bytes.withUnsafeBufferPointer { src in
                    if let base = src.baseAddress {
                        _ = memcpy(dest, base, src.count)
                    }
                }
            }
        }
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sock in
                connect(fd, sock, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 { throw LocalManagementError.connectionLost }
        var remaining = payload
        while !remaining.isEmpty {
            let wrote = remaining.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return write(fd, base, raw.count)
            }
            if wrote <= 0 { throw LocalManagementError.connectionLost }
            remaining.removeFirst(wrote)
        }
        return try LocalManagementFraming.decodeResponse(readFrame(fd))
    }

    private func readFrame(_ fd: Int32) throws -> Data {
        let prefix = try readExact(fd, 4)
        let length = try LocalManagementFraming.payloadLength(prefix: prefix)
        return try readExact(fd, length)
    }

    private func readExact(_ fd: Int32, _ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let readCount = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return read(fd, base, raw.count)
            }
            if readCount <= 0 { throw LocalManagementError.connectionLost }
            data.append(contentsOf: buffer.prefix(readCount))
        }
        return data
    }
#endif
