import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

@Suite("Home device reachability")
struct HomeDeviceReachabilityMonitorTests {
    @Test func `three concurrent callers share one in-flight probe`() async {
        let monitor = HomeDeviceReachabilityMonitor()
        let report = HomeDeviceHealthReport(
            devices: [],
            totals: HomeDeviceHealthTotals(
                devices: 0,
                reachable: 0,
                unreachable: 0,
                workloadCount: nil,
                healthCounts: [:],
            ),
        )
        let park = ProbePark()
        let makes = MakeCounter()
        let callers = MakeCounter()
        async let first: HomeDeviceHealthReport = monitor.joinProbe {
            makes.record()
            await park.hold()
            return report
        }
        await park.untilHeld()
        async let second: HomeDeviceHealthReport = joinShared(
            monitor,
            report: report,
            callers: callers,
            makes: makes,
        )
        async let third: HomeDeviceHealthReport = joinShared(
            monitor,
            report: report,
            callers: callers,
            makes: makes,
        )
        while callers.count < 2 {
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(20))
        let started = ContinuousClock.now
        park.release()
        let results = await [first, second, third]
        let elapsed = started.duration(to: .now)
        #expect(results == [report, report, report])
        #expect(makes.count == 1)
        #expect(elapsed < .nanoseconds(Int64(HomeDeviceProxy.healthProbeBudgetNanoseconds)))
    }
}

private func joinShared(
    _ monitor: HomeDeviceReachabilityMonitor,
    report: HomeDeviceHealthReport,
    callers: MakeCounter,
    makes: MakeCounter,
) async -> HomeDeviceHealthReport {
    callers.record()
    return await monitor.joinProbe {
        makes.record()
        return report
    }
}

private final class ProbePark: @unchecked Sendable {
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var isHeld = false
    private var released = false

    func untilHeld() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isHeld {
                lock.unlock()
                continuation.resume()
                return
            }
            entered = continuation
            lock.unlock()
        }
    }

    func hold() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            isHeld = true
            let entered = self.entered
            self.entered = nil
            if released {
                lock.unlock()
                entered?.resume()
                continuation.resume()
                return
            }
            held = continuation
            lock.unlock()
            entered?.resume()
        }
    }

    func release() {
        lock.lock()
        released = true
        let held = self.held
        self.held = nil
        lock.unlock()
        held?.resume()
    }
}

private final class MakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func record() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
