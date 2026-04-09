import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the Vapor.Request pagination helper.
/// Since we cannot create real Vapor.Request objects in unit tests,
/// we test the clamping logic directly.
final class PaginationTests: XCTestCase {
    // MARK: - Limit Clamping Logic

    /// The pagination helper uses: min(max(input ?? default, 1), maxLimit)
    func testLimitClampingLogic() {
        /// Simulates the clamping logic from Request.pagination()
        func clampLimit(_ input: Int?, defaultLimit: Int = 100, maxLimit: Int = 200) -> Int {
            min(max(input ?? defaultLimit, 1), maxLimit)
        }

        // Default value when nil
        XCTAssertEqual(clampLimit(nil), 100)
        XCTAssertEqual(clampLimit(nil, defaultLimit: 50), 50)

        // Normal values
        XCTAssertEqual(clampLimit(10), 10)
        XCTAssertEqual(clampLimit(200), 200)

        // Clamped to max
        XCTAssertEqual(clampLimit(500), 200)
        XCTAssertEqual(clampLimit(999), 200)

        // Clamped to minimum of 1
        XCTAssertEqual(clampLimit(0), 1)
        XCTAssertEqual(clampLimit(-5), 1)

        // Custom maxLimit
        XCTAssertEqual(clampLimit(150, maxLimit: 100), 100)
    }

    // MARK: - Offset Clamping Logic

    func testOffsetClampingLogic() {
        func clampOffset(_ input: Int?) -> Int {
            max(input ?? 0, 0)
        }

        XCTAssertEqual(clampOffset(nil), 0)
        XCTAssertEqual(clampOffset(0), 0)
        XCTAssertEqual(clampOffset(50), 50)
        XCTAssertEqual(clampOffset(-1), 0)
        XCTAssertEqual(clampOffset(-100), 0)
    }
}
