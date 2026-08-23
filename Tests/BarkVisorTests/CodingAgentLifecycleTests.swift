import Foundation
import GRDB
import Testing
@testable import BarkVisorCore

struct CodingAgentLifecycleTests {
    private func anchorDate() throws -> Date {
        try #require(iso8601.date(from: "2026-08-23T12:00:00Z"))
    }

    @Test func `ttl default is stop not destroy or suspend`() {
        #expect(CodingAgentLifecycle.expiryAction == "stop")
        #expect(CodingAgentLifecycle.expiryAction != "destroy")
        #expect(CodingAgentLifecycle.expiryAction != "suspend")
        #expect(CodingAgentLifecycle.defaultTTLSeconds == 4 * 60 * 60)
        #expect(CodingAgentLifecycle.warningLeadSeconds == 15 * 60)
        #expect(CodingAgentLifecycle.actions == ["resume", "reset", "burn"])
        #expect(CodingAgentLifecycle.noPushCopy == "NO PUSH")
        #expect(CodingAgentLifecycle.gitStampPath == "/var/lib/barkvisor/last-git-push")
    }

    @Test func `clock starts on begin and expires after ttl`() throws {
        let start = try anchorDate()
        var session = CodingAgentLifecycle.seed(
            ttlSeconds: 3_600,
            grant: "home-ollama",
            cloudImageId: "img-1",
            diskSizeGB: 20,
        )
        #expect(session.expiresAt == nil)
        CodingAgentLifecycle.beginClock(&session, now: start)
        #expect(session.startedAt == iso8601.string(from: start))
        #expect(session.expiresAt == iso8601.string(from: start.addingTimeInterval(3_600)))
        #expect(session.receipt == nil)

        let almost = start.addingTimeInterval(3_600 - 1)
        #expect(!CodingAgentLifecycle.shouldExpire(expiresAt: session.expiresAt, vmState: "running", now: almost))
        #expect(CodingAgentLifecycle.shouldExpire(
            expiresAt: session.expiresAt, vmState: "running", now: start.addingTimeInterval(3_600),
        ))
        #expect(!CodingAgentLifecycle.shouldExpire(
            expiresAt: session.expiresAt, vmState: "stopped", now: start.addingTimeInterval(3_600),
        ))
        CodingAgentLifecycle.beginClock(&session, now: almost)
        #expect(session.expiresAt == iso8601.string(from: start.addingTimeInterval(3_600)))
    }

    @Test func `warns 15 minutes before expiry once`() throws {
        let start = try anchorDate()
        var session = CodingAgentLifecycle.seed(
            ttlSeconds: 3_600, grant: "home-ollama", cloudImageId: nil, diskSizeGB: nil,
        )
        CodingAgentLifecycle.beginClock(&session, now: start)
        let warnAt = start.addingTimeInterval(3_600 - 15 * 60)
        #expect(!CodingAgentLifecycle.shouldWarn(expiresAt: session.expiresAt, warnedAt: nil, now: warnAt.addingTimeInterval(-1)))
        #expect(CodingAgentLifecycle.shouldWarn(expiresAt: session.expiresAt, warnedAt: nil, now: warnAt))
        #expect(!CodingAgentLifecycle.shouldWarn(
            expiresAt: session.expiresAt, warnedAt: iso8601.string(from: warnAt), now: warnAt,
        ))
        let view = CodingAgentLifecycle.view(session, now: warnAt, vmState: "running")
        #expect(view.warning)
        #expect(view.remainingSeconds == 15 * 60)
        #expect(view.expiryAction == "stop")
        #expect(!CodingAgentLifecycle.view(session, now: warnAt, vmState: "stopped").warning)
    }

    @Test func `receipt is NO PUSH when git stamp is missing`() throws {
        let start = try anchorDate()
        let receipt = CodingAgentLifecycle.makeReceipt(now: start, reason: "ttl", lastGitPushAt: nil)
        #expect(receipt.noPush)
        #expect(receipt.lastGitPushAt == nil)
        #expect(receipt.reason == "ttl")
        #expect(receipt.stoppedAt == iso8601.string(from: start))
        #expect(CodingAgentLifecycle.parseGitStamp(" \nnot-a-date\n") == nil)
        #expect(CodingAgentLifecycle.parseGitStamp("2026-08-23T11:00:00Z\n") != nil)
        let pushed = CodingAgentLifecycle.makeReceipt(
            now: start, reason: "stop", lastGitPushAt: "2026-08-23T11:00:00Z\n",
        )
        #expect(!pushed.noPush)
        #expect(pushed.lastGitPushAt != nil)
    }

    @Test func `kill unloads grant only when this was the last agent session`() {
        #expect(CodingAgentLifecycle.shouldUnloadGrant(usesHomeOllama: true, otherRunningAgentSessions: 0))
        #expect(!CodingAgentLifecycle.shouldUnloadGrant(usesHomeOllama: true, otherRunningAgentSessions: 1))
        #expect(!CodingAgentLifecycle.shouldUnloadGrant(usesHomeOllama: false, otherRunningAgentSessions: 0))
        #expect(CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: CodingAgentLifecycle.ttlReason))
        #expect(CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: CodingAgentLifecycle.forceReason))
        #expect(CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: CodingAgentLifecycle.burnReason))
        #expect(!CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: CodingAgentLifecycle.stopReason))
        #expect(!CodingAgentLifecycle.shouldUnloadGrantAfterStop(reason: CodingAgentLifecycle.resetReason))
    }

    @Test func `view hides receipt while the VM is live`() throws {
        let start = try anchorDate()
        var session = CodingAgentLifecycle.seed(
            ttlSeconds: 3_600, grant: "home-ollama", cloudImageId: nil, diskSizeGB: nil,
        )
        CodingAgentLifecycle.beginClock(&session, now: start)
        session.receipt = CodingAgentLifecycle.makeReceipt(now: start, reason: "stop", lastGitPushAt: nil)
        #expect(CodingAgentLifecycle.view(session, now: start, vmState: "running").receipt == nil)
        #expect(CodingAgentLifecycle.view(session, now: start, vmState: "starting").receipt == nil)
        #expect(CodingAgentLifecycle.view(session, now: start, vmState: "stopping").receipt == nil)
        #expect(CodingAgentLifecycle.view(session, now: start, vmState: "stopped").receipt != nil)
        #expect(CodingAgentLifecycle.view(session, now: start, vmState: "error").receipt != nil)
    }

    @Test func `beginClock on resume clears a stale receipt without resetting TTL`() throws {
        let start = try anchorDate()
        var session = CodingAgentLifecycle.seed(
            ttlSeconds: 3_600, grant: "home-ollama", cloudImageId: nil, diskSizeGB: nil,
        )
        CodingAgentLifecycle.beginClock(&session, now: start)
        let expires = session.expiresAt
        session.receipt = CodingAgentLifecycle.makeReceipt(now: start, reason: "stop", lastGitPushAt: nil)
        session.pendingStopReason = CodingAgentLifecycle.stopReason
        let resumeAt = start.addingTimeInterval(60)
        CodingAgentLifecycle.beginClock(&session, now: resumeAt)
        #expect(session.receipt == nil)
        #expect(session.pendingStopReason == nil)
        #expect(session.expiresAt == expires)
    }

    @Test func `user-data records last git push`() throws {
        let yaml = CodingAgentImage.userData(openaiBaseURL: CodingAgentImage.homeOllamaGrantURL)
        try CloudInitService.validateUserData(yaml)
        #expect(yaml.contains("/etc/git-hooks/pre-push"))
        #expect(yaml.contains(CodingAgentLifecycle.gitStampPath))
        #expect(yaml.contains("core.hooksPath /etc/git-hooks"))
    }

    @Test func `tick waits for guest exit before receipt and grant unload`() async throws {
        let start = try anchorDate()
        let (dir, pool, vmID) = try await isolatedAgentSession(startedAt: start, ttlSeconds: 60)
        defer { try? FileManager.default.removeItem(at: dir) }
        let runtime = FakeCodingAgentRuntime()
        runtime.active = true
        let unloader = RecordingUnloader()
        let expired = start.addingTimeInterval(61)

        await CodingAgentLifecycleService.tick(
            now: expired, vmManager: runtime, db: pool, unloader: unloader,
        )
        #expect(runtime.stopCount == 1)
        #expect(runtime.lastMethod == "acpi")
        var session = try await loadedSession(vmID: vmID, db: pool)
        #expect(session?.receipt == nil)
        #expect(session?.pendingStopReason == CodingAgentLifecycle.ttlReason)
        #expect(!unloader.didUnload)

        await CodingAgentLifecycleService.tick(
            now: expired, vmManager: runtime, db: pool, unloader: unloader,
        )
        #expect(runtime.stopCount == 1)
        #expect(!unloader.didUnload)

        runtime.active = false
        await CodingAgentLifecycleService.tick(
            now: expired, vmManager: runtime, db: pool, unloader: unloader,
        )
        session = try await loadedSession(vmID: vmID, db: pool)
        #expect(session?.receipt?.reason == CodingAgentLifecycle.ttlReason)
        #expect(session?.pendingStopReason == nil)
        #expect(unloader.didUnload)
    }

    @Test func `force stop unloads grant after termination when last agent`() async throws {
        let start = try anchorDate()
        let (dir, pool, vmID) = try await isolatedAgentSession(startedAt: start, ttlSeconds: 60)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unloader = RecordingUnloader()

        await CodingAgentLifecycleService.markStopIntent(
            vmID: vmID, reason: CodingAgentLifecycle.forceReason, db: pool,
        )
        var session = try await loadedSession(vmID: vmID, db: pool)
        #expect(session?.receipt == nil)
        #expect(session?.pendingStopReason == CodingAgentLifecycle.forceReason)

        await CodingAgentLifecycleService.onTerminated(
            vmID: vmID, db: pool, now: start, unloader: unloader,
        )
        session = try await loadedSession(vmID: vmID, db: pool)
        #expect(session?.receipt?.reason == CodingAgentLifecycle.forceReason)
        #expect(unloader.didUnload)
    }

    @Test func `graceful stop writes receipt without unloading grant`() async throws {
        let start = try anchorDate()
        let (dir, pool, vmID) = try await isolatedAgentSession(startedAt: start, ttlSeconds: 60)
        defer { try? FileManager.default.removeItem(at: dir) }
        let unloader = RecordingUnloader()

        await CodingAgentLifecycleService.markStopIntent(
            vmID: vmID, reason: CodingAgentLifecycle.stopReason, db: pool,
        )
        await CodingAgentLifecycleService.onTerminated(
            vmID: vmID, db: pool, now: start, unloader: unloader,
        )
        let session = try await loadedSession(vmID: vmID, db: pool)
        #expect(session?.receipt?.reason == CodingAgentLifecycle.stopReason)
        #expect(!unloader.didUnload)
    }
}

private final class FakeCodingAgentRuntime: CodingAgentControlling, @unchecked Sendable {
    var stopCount = 0
    var lastMethod: String?
    var active = true

    func stop(vmID _: String, force _: Bool, method: String) async throws {
        stopCount += 1
        lastMethod = method
    }

    func start(vmID _: String) async throws {}

    func isActiveOrStarting(_: String) async -> Bool {
        active
    }
}

private final class RecordingUnloader: CodingAgentModelUnloading, @unchecked Sendable {
    var didUnload = false

    func unloadRunningModels() async throws {
        didUnload = true
    }
}

private func isolatedAgentSession(
    vmID: String = "vm-agent",
    startedAt: Date,
    ttlSeconds: Int,
) async throws -> (URL, DatabasePool, String) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
        "session-ttl-\(UUID().uuidString)",
    )
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let pool = try DatabasePool(path: dir.appendingPathComponent("test.sqlite").path)
    try AppDatabase.makeMigrator().migrate(pool)
    let created = iso8601.string(from: startedAt)
    let disk = Disk(
        id: "disk-1", name: "boot", path: dir.appendingPathComponent("boot.qcow2").path,
        sizeBytes: 1_073_741_824, format: "qcow2", vmId: nil,
        autoCreated: false, status: "ready", createdAt: created,
    )
    var session = CodingAgentLifecycle.seed(
        ttlSeconds: ttlSeconds, grant: "home-ollama", cloudImageId: "img-1", diskSizeGB: 10,
    )
    CodingAgentLifecycle.beginClock(&session, now: startedAt)
    var vm = VM(
        id: vmID, name: "coder", vmType: "linux-arm64", state: "running",
        cpuCount: 2, memoryMb: 2_048, bootDiskId: disk.id, networkId: nil, cloudInitPath: nil,
        description: nil, bootOrder: nil, displayResolution: nil, additionalDiskIds: nil,
        uefi: true, tpmEnabled: false,
        macAddress: nil, sharedPaths: nil, portForwards: nil,
        autoCreated: false, pendingChanges: false,
        workloadClass: "agent",
        createdAt: created, updatedAt: created,
    )
    vm.setSession(session)
    let row = vm
    try await pool.write { db in
        try disk.insert(db)
        try row.insert(db)
    }
    return (dir, pool, vmID)
}

private func loadedSession(vmID: String, db: DatabasePool) async throws -> CodingAgentSessionState? {
    try await db.read { db in try VM.fetchOne(db, key: vmID)?.decodedSession }
}
