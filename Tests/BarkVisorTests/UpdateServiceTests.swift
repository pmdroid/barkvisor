import XCTest
@testable import BarkVisorCore

final class UpdateServiceTests: XCTestCase {
    // MARK: - Semver Comparison

    func testPrereleaseNumericBump() {
        XCTAssertTrue(UpdateService.isVersion("1.0.0-alpha.2", newerThan: "1.0.0-alpha.1"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0-alpha.3", newerThan: "1.0.0-alpha.2"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0-alpha.10", newerThan: "1.0.0-alpha.9"))
    }

    func testBetaNewerThanAlpha() {
        XCTAssertTrue(UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0-alpha.3"))
    }

    func testRcNewerThanBeta() {
        XCTAssertTrue(UpdateService.isVersion("1.0.0-rc.1", newerThan: "1.0.0-beta.2"))
    }

    func testReleaseNewerThanPrerelease() {
        XCTAssertTrue(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-rc.1"))
    }

    func testNotNewer() {
        XCTAssertFalse(UpdateService.isVersion("1.0.0-alpha.1", newerThan: "1.0.0-alpha.2"))
        XCTAssertFalse(UpdateService.isVersion("1.0.0-alpha.1", newerThan: "1.0.0-alpha.1"))
        XCTAssertFalse(UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
    }

    func testMajorMinorPatchTakesPrecedence() {
        XCTAssertTrue(UpdateService.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateService.isVersion("1.1.0", newerThan: "1.0.9"))
        XCTAssertTrue(UpdateService.isVersion("2.0.0-alpha.1", newerThan: "1.9.9"))
    }

    func testSameVersionNotNewer() {
        XCTAssertFalse(UpdateService.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("2.1.3", newerThan: "2.1.3"))
    }
}
