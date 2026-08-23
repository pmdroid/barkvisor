import Foundation
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
    }

    @Test func `user-data records last git push`() throws {
        let yaml = CodingAgentImage.userData(openaiBaseURL: CodingAgentImage.homeOllamaGrantURL)
        try CloudInitService.validateUserData(yaml)
        #expect(yaml.contains("/etc/git-hooks/pre-push"))
        #expect(yaml.contains(CodingAgentLifecycle.gitStampPath))
        #expect(yaml.contains("core.hooksPath /etc/git-hooks"))
    }
}
