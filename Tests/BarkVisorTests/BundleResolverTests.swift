import Testing
@testable import BarkVisorCore

struct BundleResolverTests {
    @Test func `helperCandidates prefer Homebrew on macOS`() {
        let qemu = BundleResolver.helperCandidates("qemu-system-aarch64")
        #if os(macOS)
            #expect(qemu.first == "/opt/homebrew/bin/qemu-system-aarch64")
            #expect(qemu.contains("/usr/local/bin/qemu-system-aarch64"))
            #expect(qemu.last?.hasSuffix("/libexec/barkvisor/qemu-system-aarch64") == true)
        #else
            #expect(qemu.first?.hasSuffix("/libexec/barkvisor/qemu-system-aarch64") == true)
            #expect(qemu.contains("/usr/bin/qemu-system-aarch64"))
        #endif
    }

    @Test func `optHelperCandidates prefer Homebrew opt on macOS`() {
        let paths = BundleResolver.optHelperCandidates("socket_vmnet", package: "socket_vmnet")
        #if os(macOS)
            #expect(paths.first == "/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet")
            #expect(paths.last?.hasSuffix("/libexec/barkvisor/socket_vmnet") == true)
        #else
            #expect(paths.contains("/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet"))
        #endif
    }
}
