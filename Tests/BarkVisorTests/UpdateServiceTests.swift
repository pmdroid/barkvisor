import Foundation
import Testing
@testable import BarkVisorCore

struct UpdateServiceTests {
    // MARK: - Semver Comparison

    @Test func `prerelease numeric bump`() {
        #expect(UpdateService.isVersion("1.0.0-alpha.2", newerThan: "1.0.0-alpha.1"))
        #expect(UpdateService.isVersion("1.0.0-alpha.3", newerThan: "1.0.0-alpha.2"))
        #expect(UpdateService.isVersion("1.0.0-alpha.10", newerThan: "1.0.0-alpha.9"))
    }

    @Test func `beta newer than alpha`() {
        #expect(UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0-alpha.3"))
    }

    @Test func `rc newer than beta`() {
        #expect(UpdateService.isVersion("1.0.0-rc.1", newerThan: "1.0.0-beta.2"))
    }

    @Test func `release newer than prerelease`() {
        #expect(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        #expect(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-rc.1"))
    }

    @Test func `not newer`() {
        #expect(!UpdateService.isVersion("1.0.0-alpha.1", newerThan: "1.0.0-alpha.2"))
        #expect(!UpdateService.isVersion("1.0.0-alpha.1", newerThan: "1.0.0-alpha.1"))
        #expect(!UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    @Test func `major minor patch takes precedence`() {
        #expect(UpdateService.isVersion("2.0.0", newerThan: "1.9.9"))
        #expect(UpdateService.isVersion("1.1.0", newerThan: "1.0.9"))
        #expect(UpdateService.isVersion("2.0.0-alpha.1", newerThan: "1.9.9"))
    }

    @Test func `same version not newer`() {
        #expect(!UpdateService.isVersion("1.0.0", newerThan: "1.0.0"))
        #expect(!UpdateService.isVersion("2.1.3", newerThan: "2.1.3"))
    }
}
