import BarkVisorCore
import Foundation

public final class SplitBarkDaemon: @unchecked Sendable {
    private let lock = NSLock()
    private var stopping = false
    private let runtime: VaporServer
    private let management: LocalManagementSocketServer
    private let http: UnixSocketRelay
    private let agent: UnixSocketRelay
    private let paths: DaemonAPIPaths
    private let permissions: SocketPermissionPlan

    public init(socketDirectory: URL) {
        paths = DaemonAPIPaths(directory: socketDirectory)
        let uid = WorkloadPrivilegeDrop.currentEUID()
        permissions = SocketPermissionPlan.forDaemonEUID(uid)
        let allowed = LocalManagementPeers.allowlist(
            daemonEUID: uid,
            serverUID: WorkloadPrivilegeDrop.uid(forUser: "barkvisor"),
        )
        runtime = VaporServer(daemonPaths: paths)
        management = LocalManagementSocketServer(
            path: ManagementSocketPath.path(socketDir: socketDirectory),
            session: LocalManagementSession(policy: LocalManagementPolicy(
                allowedPeerUIDs: allowed,
                memberships: [],
                resources: ResourcePolicy(allowedRoots: [], allowedMounts: [], allowedDevices: []),
            )),
            directoryMode: permissions.directoryMode,
            socketMode: permissions.socketMode,
        )
        http = UnixSocketRelay(
            listener: .unix(path: paths.http, mode: permissions.socketMode, allowedUIDs: allowed),
            destination: paths.privateHTTP,
            destinationUID: uid,
        )
        agent = UnixSocketRelay(
            listener: .unix(path: paths.agent, mode: permissions.socketMode, allowedUIDs: allowed),
            destination: paths.privateAgent,
            destinationUID: uid,
        )
    }

    public func run() async throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: permissions.directoryMode)],
            ofItemAtPath: paths.directory.path,
        )
        try FileManager.default.createDirectory(at: paths.privateDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: paths.privateDirectory.path,
        )
        try await runtime.start()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.http.run() }
                group.addTask { try await self.agent.run() }
                group.addTask {
                    try await self.http.waitUntilListening()
                    try await self.agent.waitUntilListening()
                    try await self.management.run()
                }
                do {
                    try await group.next()
                } catch {
                    self.http.stop()
                    self.agent.stop()
                    self.management.stop()
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            await stop()
            throw error
        }
    }

    public func stop() async {
        guard lock.withLock({
            if stopping { return false }
            stopping = true
            return true
        }) else { return }
        http.stop()
        agent.stop()
        management.stop()
        await runtime.stop()
    }
}
