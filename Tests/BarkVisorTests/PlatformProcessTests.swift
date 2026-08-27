import Foundation
import Testing
@testable import BarkVisorCore

struct PlatformProcessTests {
    @Test func `run captures stdout from echo`() throws {
        #if os(macOS) || os(Linux)
            let result = try PlatformProcess.run(
                path: "/bin/echo",
                arguments: ["hello-barkvisor"],
                timeout: 30,
            )
            #expect(result.succeeded)
            #expect(result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) == "hello-barkvisor")
        #endif
    }

    @Test func `run reports non-zero exit`() throws {
        #if os(macOS) || os(Linux)
            // `false` exits 1
            let result = try PlatformProcess.run(path: "/usr/bin/false", arguments: [], timeout: 30)
            #expect(!result.succeeded)
            #expect(result.exitCode != 0)
        #endif
    }

    @Test func `run times out`() throws {
        #if os(macOS) || os(Linux)
            #expect(throws: BarkVisorError.self) {
                try PlatformProcess.run(path: "/bin/sleep", arguments: ["30"], timeout: 0.3)
            }
        #endif
    }

    @Test func `arguments reads this process argv`() {
        #if os(macOS) || os(Linux)
            let pid = ProcessInfo.processInfo.processIdentifier
            let args = PlatformProcess.arguments(pid: pid)
            #expect(args != nil)
            #expect(args?.isEmpty == false)
        #endif
    }
}
