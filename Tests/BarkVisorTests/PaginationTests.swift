import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the Vapor.Request pagination helper.
/// Since we cannot create real Vapor.Request objects in unit tests,
/// we test the clamping logic directly.
struct PaginationTests {
    // MARK: - Limit Clamping Logic

    /// The pagination helper uses: min(max(input ?? default, 1), maxLimit)
    @Test func `limit clamping logic`() {
        /// Simulates the clamping logic from Request.pagination()
        func clampLimit(_ input: Int?, defaultLimit: Int = 100, maxLimit: Int = 200) -> Int {
            min(max(input ?? defaultLimit, 1), maxLimit)
        }

        // Default value when nil
        #expect(clampLimit(nil) == 100)
        #expect(clampLimit(nil, defaultLimit: 50) == 50)

        // Normal values
        #expect(clampLimit(10) == 10)
        #expect(clampLimit(200) == 200)

        // Clamped to max
        #expect(clampLimit(500) == 200)
        #expect(clampLimit(999) == 200)

        // Clamped to minimum of 1
        #expect(clampLimit(0) == 1)
        #expect(clampLimit(-5) == 1)

        // Custom maxLimit
        #expect(clampLimit(150, maxLimit: 100) == 100)
    }

    // MARK: - Offset Clamping Logic

    @Test func `offset clamping logic`() {
        func clampOffset(_ input: Int?) -> Int {
            max(input ?? 0, 0)
        }

        #expect(clampOffset(nil) == 0)
        #expect(clampOffset(0) == 0)
        #expect(clampOffset(50) == 50)
        #expect(clampOffset(-1) == 0)
        #expect(clampOffset(-100) == 0)
    }
}
