import Foundation
import GRDB

/// Persistence, guest probe, TTL stop, reset/burn, and grant unload (PAS-273).
public enum CodingAgentLifecycleService {
    public static func persist(_ session: CodingAgentSessionState, vmID: String, db: DatabasePool) async throws {
        let json = JSONColumnCoding.encode(session)
        let now = iso8601.string(from: Date())
        try await db.write { db in
            try db.execute(
                sql: "UPDATE vms SET sessionJson = ?, updatedAt = ? WHERE id = ?",
                arguments: [json, now, vmID],
            )
        }
    }

    public static func load(vmID: String, db: DatabasePool) async throws -> (VM, CodingAgentSessionState?) {
        let vm = try await db.read { db in try VM.fetchOne(db, key: vmID) }
        guard let vm else { throw BarkVisorError.notFound("Workload not found") }
        return (vm, vm.decodedSession)
    }

    public static func requireAgentSession(vm: VM) throws -> CodingAgentSessionState {
        guard (try? WorkloadClass.parse(vm.workloadClass)) == .agent else {
            throw BarkVisorError.badRequest("Coding session actions need an Agent Workload")
        }
        guard let session = vm.decodedSession else {
            throw BarkVisorError.badRequest("Coding session is not on this Workload")
        }
        return session
    }

    public static func onStart(vm: VM, db: DatabasePool, now: Date = Date()) async {
        guard (try? WorkloadClass.parse(vm.workloadClass)) == .agent else { return }
        var session = vm.decodedSession ?? CodingAgentLifecycle.seed(
            grant: CodingAgentSession.usesHomeOllamaGrant(
                userData: CloudInitService.storedUserData(vmID: vm.id),
            ) ? CodingAgentSession.grant : "byo",
            cloudImageId: nil,
            diskSizeGB: nil,
        )
        CodingAgentLifecycle.beginClock(&session, now: now)
        try? await persist(session, vmID: vm.id, db: db)
    }

    /// Snapshot git stamp and stop reason while the guest is still up. Does not
    /// write `session.receipt` — that waits for `onTerminated`.
    public static func markStopIntent(vmID: String, reason: String, db: DatabasePool) async {
        guard let vm = try? await db.read({ db in try VM.fetchOne(db, key: vmID) }) else { return }
        guard (try? WorkloadClass.parse(vm.workloadClass)) == .agent else { return }
        guard var session = vm.decodedSession else { return }
        if session.pendingStopReason == nil {
            session.pendingStopReason = reason
        }
        if session.pendingGitStamp == nil {
            let stamp = GuestAgentChannel.readTextFile(
                socketPath: VMSockets(vmID: vmID).guestAgent.path,
                path: CodingAgentLifecycle.gitStampPath,
            )
            session.pendingGitStamp = CodingAgentLifecycle.parseGitStamp(stamp)
        }
        try? await persist(session, vmID: vmID, db: db)
    }

    public static func onStop(vmID: String, db: DatabasePool, reason: String, now: Date = Date()) async {
        guard let vm = try? await db.read({ db in try VM.fetchOne(db, key: vmID) }) else { return }
        guard (try? WorkloadClass.parse(vm.workloadClass)) == .agent else { return }
        guard var session = vm.decodedSession else { return }
        let resolved = session.pendingStopReason ?? reason
        let stamp = session.pendingGitStamp
        session.receipt = CodingAgentLifecycle.makeReceipt(
            now: now, reason: resolved, lastGitPushAt: stamp,
        )
        session.pendingStopReason = nil
        session.pendingGitStamp = nil
        try? await persist(session, vmID: vmID, db: db)
    }

    /// Receipt + optional grant unload after the guest process is gone.
    public static func onTerminated(
        vmID: String,
        db: DatabasePool,
        now: Date = Date(),
        unloader: (any CodingAgentModelUnloading)? = nil,
    ) async {
        await onStop(vmID: vmID, db: db, reason: CodingAgentLifecycle.stopReason, now: now)
        guard let vm = try? await db.read({ db in try VM.fetchOne(db, key: vmID) }) else { return }
        let reason = vm.decodedSession?.receipt?.reason ?? CodingAgentLifecycle.stopReason
        guard CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: reason) else { return }
        await unloadGrantIfLast(stopped: vm, db: db, unloader: unloader)
    }

    public static func tick(
        now: Date,
        vmManager: some CodingAgentControlling,
        db: DatabasePool,
        unloader: (any CodingAgentModelUnloading)? = nil,
    ) async {
        let vms: [VM]
        do {
            vms = try await db.read { db in try VM.fetchAll(db) }
        } catch {
            return
        }
        for vm in vms {
            guard (try? WorkloadClass.parse(vm.workloadClass)) == .agent else { continue }
            guard var session = vm.decodedSession else { continue }
            if CodingAgentLifecycle.shouldWarn(
                expiresAt: session.expiresAt, warnedAt: session.warnedAt, now: now,
            ) {
                session.warnedAt = iso8601.string(from: now)
                try? await persist(session, vmID: vm.id, db: db)
            }
            if session.pendingStopReason != nil {
                if await vmManager.isActiveOrStarting(vm.id) {
                    if session.pendingStopReason == CodingAgentLifecycle.ttlReason {
                        guard await requestTTLStop(vmID: vm.id, vmManager: vmManager) else {
                            continue
                        }
                    } else {
                        continue
                    }
                }
                await onTerminated(vmID: vm.id, db: db, now: now, unloader: unloader)
                continue
            }
            guard CodingAgentLifecycle.shouldExpire(
                expiresAt: session.expiresAt, vmState: vm.state, now: now,
            ) else { continue }
            await markStopIntent(vmID: vm.id, reason: CodingAgentLifecycle.ttlReason, db: db)
            guard await requestTTLStop(vmID: vm.id, vmManager: vmManager) else { continue }
            await onTerminated(vmID: vm.id, db: db, now: now, unloader: unloader)
        }
    }

    public static func resume(vmID: String, vmManager: some CodingAgentControlling, db: DatabasePool) async throws {
        let (vm, _) = try await load(vmID: vmID, db: db)
        _ = try requireAgentSession(vm: vm)
        if vm.state == "running" || vm.state == "starting" {
            throw BarkVisorError.conflict("Session is already running")
        }
        try await vmManager.start(vmID: vmID)
    }

    public static func reset(vmID: String, vmManager: some CodingAgentControlling, db: DatabasePool) async throws {
        var (vm, _) = try await load(vmID: vmID, db: db)
        var session = try requireAgentSession(vm: vm)
        if vm.state == "running" || vm.state == "starting" || vm.state == "stopping" {
            await markStopIntent(vmID: vmID, reason: CodingAgentLifecycle.resetReason, db: db)
            try? await vmManager.stop(vmID: vmID, force: true, method: "force")
            try await waitUntilInactive(vmID: vmID, vmManager: vmManager)
            (vm, _) = try await load(vmID: vmID, db: db)
            session = try requireAgentSession(vm: vm)
        }
        guard vm.state == "stopped" || vm.state == "error" else {
            throw BarkVisorError.conflict("Reset needs a stopped Workload")
        }
        guard let imageID = session.cloudImageId, !imageID.isEmpty else {
            throw BarkVisorError.badRequest("Reset needs the Library image this session was created from")
        }
        let image = try await db.read { db in try VMImage.fetchOne(db, key: imageID) }
        guard let image, image.status == "ready", let imagePath = image.path, !imagePath.isEmpty else {
            throw BarkVisorError.badRequest("Library image is not ready")
        }
        let bootDiskId = vm.bootDiskId
        let disk = try await db.read { db in try Disk.fetchOne(db, key: bootDiskId) }
        guard let disk else { throw BarkVisorError.notFound("Boot disk not found") }
        let dest = URL(fileURLWithPath: disk.path)
        try? FileManager.default.removeItem(at: dest)
        try DiskService.cloneAndResize(sourcePath: imagePath, destPath: dest, sizeGB: session.diskSizeGB)
        let size = (try? DiskService.getVirtualSize(path: dest.path)) ?? disk.sizeBytes
        let now = iso8601.string(from: Date())
        session = CodingAgentLifecycle.seed(
            ttlSeconds: session.ttlSeconds,
            grant: session.grant,
            cloudImageId: session.cloudImageId,
            diskSizeGB: session.diskSizeGB,
        )
        let json = JSONColumnCoding.encode(session)
        try await db.write { db in
            try db.execute(
                sql: "UPDATE disks SET status = 'ready', sizeBytes = ? WHERE id = ?",
                arguments: [size, disk.id],
            )
            try db.execute(
                sql: """
                UPDATE vms SET state = 'stopped', sessionJson = ?, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [json, now, vmID],
            )
        }
    }

    public static func burn(
        vmID: String,
        vmManager: VMManager,
        backgroundTasks: BackgroundTaskManager,
        db: DatabasePool,
        unloader: (any CodingAgentModelUnloading)? = nil,
    ) async throws -> (taskID: String, vmName: String) {
        let (vm, _) = try await load(vmID: vmID, db: db)
        _ = try requireAgentSession(vm: vm)
        if vm.state == "running" || vm.state == "starting" || vm.state == "stopping" {
            await markStopIntent(vmID: vmID, reason: CodingAgentLifecycle.burnReason, db: db)
            try? await vmManager.stop(vmID: vmID, force: true, method: "force")
        }
        try await waitUntilInactive(vmID: vmID, vmManager: vmManager)
        await unloadGrantIfLast(stopped: vm, db: db, unloader: unloader)
        return try await VMLifecycleService.deleteVM(
            id: vmID, keepDisk: false, vmManager: vmManager,
            backgroundTasks: backgroundTasks, db: db,
        )
    }

    public static func unloadGrantIfLast(
        stopped: VM,
        db: DatabasePool,
        unloader: (any CodingAgentModelUnloading)? = nil,
    ) async {
        let session = stopped.decodedSession
        let usesGrant = CodingAgentLifecycle.usesHomeOllamaGrant(session?.grant ?? "")
            || CodingAgentSession.usesHomeOllamaGrant(
                userData: CloudInitService.storedUserData(vmID: stopped.id),
            )
        let stoppedID = stopped.id
        let others: Int
        do {
            others = try await db.read { db in
                try VM.fetchAll(db).count { other in
                    other.id != stoppedID
                        && (try? WorkloadClass.parse(other.workloadClass)) == .agent
                        && (other.state == "running" || other.state == "starting")
                }
            }
        } catch {
            others = 0
        }
        guard CodingAgentLifecycle.shouldUnloadGrant(
            usesHomeOllama: usesGrant, otherRunningAgentSessions: others,
        ) else { return }
        do {
            if let unloader {
                try await unloader.unloadRunningModels()
                return
            }
            let settings = try await db.read { db in try OllamaSettings.load(from: db) }
            let client = OllamaClient(baseURL: settings.endpoint, apiKey: settings.apiKey)
            let running = try await client.ps()
            for model in running {
                try await client.unload(model: model.name)
            }
        } catch {
            Log.vm.warning(
                "Coding session grant unload failed: \(error.localizedDescription)",
                vm: stopped.id,
            )
        }
    }

    /// ACPI TTL stop. False means try again next tick: the call threw, or the guest is still up.
    private static func requestTTLStop(
        vmID: String,
        vmManager: some CodingAgentControlling,
    ) async -> Bool {
        do {
            try await vmManager.stop(vmID: vmID, force: false, method: "acpi")
        } catch {
            Log.vm.warning(
                "Coding session TTL stop failed: \(error.localizedDescription)",
                vm: vmID,
            )
            return false
        }
        return await !vmManager.isActiveOrStarting(vmID)
    }

    private static func waitUntilInactive(
        vmID: String,
        vmManager: some CodingAgentControlling,
    ) async throws {
        for _ in 0 ..< 20 {
            if await !vmManager.isActiveOrStarting(vmID) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
}

extension VMManager: CodingAgentControlling {}
