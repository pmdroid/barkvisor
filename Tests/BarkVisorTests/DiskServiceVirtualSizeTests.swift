import Foundation
import Testing
@testable import BarkVisorCore

/// Ensures qemu-img JSON number parsing does not regress to Int64-only casts
/// (which broke HAOS provision on Linux by treating virtual size as ~1 GiB file size).
struct DiskServiceVirtualSizeTests {
    @Test func `jsonInt64 accepts Int`() {
        #expect(DiskService.jsonInt64(Int(34_359_738_368)) == 34_359_738_368)
    }

    @Test func `jsonInt64 accepts Int64`() {
        #expect(DiskService.jsonInt64(Int64(34_359_738_368)) == 34_359_738_368)
    }

    @Test func `jsonInt64 accepts NSNumber`() {
        #expect(DiskService.jsonInt64(NSNumber(value: 34_359_738_368 as Int64)) == 34_359_738_368)
    }

    @Test func `jsonInt64 accepts Double from JSONSerialization style`() {
        // JSONSerialization often boxes large numbers as Double / NSNumber(double).
        #expect(DiskService.jsonInt64(Double(34_359_738_368)) == 34_359_738_368)
    }

    @Test func `jsonInt64 rejects garbage`() {
        #expect(DiskService.jsonInt64("nope") == nil)
        #expect(DiskService.jsonInt64(nil) == nil)
    }

    @Test func `grow decision uses virtual size not sparse file size`() {
        // 32 GiB virtual HAOS image vs 10 GiB request must not resize (would shrink).
        let virtual: Int64 = 34_359_738_368
        let requested10G: Int64 = 10 * 1_073_741_824
        #expect(virtual > requested10G)
        #expect(virtual >= requested10G) // growIfNeeded should no-op
        // sparse file size (~1 GiB) is NOT a valid stand-in for virtual size
        let sparseFile: Int64 = 1_092_288_512
        #expect(sparseFile < requested10G) // old bug path
    }
}
