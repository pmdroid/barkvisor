import Foundation
import Testing
@testable import BarkVisorCore

struct DeviceLoginAccountTests {
    @Test func `safe names reject flags and empty`() {
        #expect(DeviceLoginAccount.isSafeName("pascal"))
        #expect(DeviceLoginAccount.isSafeName("ubuntu"))
        #expect(DeviceLoginAccount.isSafeName("user.name"))
        #expect(!DeviceLoginAccount.isSafeName(""))
        #expect(!DeviceLoginAccount.isSafeName("-root"))
        #expect(!DeviceLoginAccount.isSafeName("has space"))
        #expect(!DeviceLoginAccount.isSafeName("root;id"))
        #expect(!DeviceLoginAccount.isSafeName(String(repeating: "a", count: 33)))
    }

    @Test func `login shells skip nologin and false`() {
        #expect(DeviceLoginAccount.isLoginShell("/bin/zsh"))
        #expect(DeviceLoginAccount.isLoginShell("/bin/bash"))
        #expect(!DeviceLoginAccount.isLoginShell(""))
        #expect(!DeviceLoginAccount.isLoginShell("/usr/sbin/nologin"))
        #expect(!DeviceLoginAccount.isLoginShell("/bin/false"))
        #expect(!DeviceLoginAccount.isLoginShell("/usr/bin/true"))
    }

    @Test func `root daemon offers login users and skips system accounts`() {
        #expect(
            DeviceLoginAccount.isOffered(
                name: "pascal", uid: 501, shell: "/bin/zsh", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "root", uid: 0, shell: "/bin/zsh", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "daemon", uid: 1, shell: "/usr/sbin/nologin", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "_www", uid: 70, shell: "/usr/bin/false", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "nobody", uid: 501, shell: "/bin/zsh", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "barkvisor", uid: 114, shell: "/bin/bash", euid: 0, platform: .linux,
            ),
        )
        #expect(
            DeviceLoginAccount.isOffered(
                name: "ubuntu", uid: 1_000, shell: "/bin/bash", euid: 0, platform: .linux,
            ),
        )
    }

    @Test func `non-root daemon only offers its own uid`() {
        #expect(
            DeviceLoginAccount.isOffered(
                name: "pascal", uid: 501, shell: "/usr/sbin/nologin", euid: 501, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isOffered(
                name: "other", uid: 502, shell: "/bin/zsh", euid: 501, platform: .macOS,
            ),
        )
    }

    @Test func `spawn never allows uid 0`() {
        #expect(
            !DeviceLoginAccount.isSpawnAllowed(
                name: "root", uid: 0, shell: "/bin/zsh", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            DeviceLoginAccount.isSpawnAllowed(
                name: "pascal", uid: 501, shell: "/bin/zsh", euid: 0, platform: .macOS,
            ),
        )
        #expect(
            DeviceLoginAccount.isSpawnAllowed(
                name: "pascal", uid: 501, shell: "/usr/sbin/nologin", euid: 501, platform: .macOS,
            ),
        )
        #expect(
            !DeviceLoginAccount.isSpawnAllowed(
                name: "other", uid: 502, shell: "/bin/zsh", euid: 501, platform: .macOS,
            ),
        )
    }

    @Test func `list never includes root`() {
        let names = DeviceLoginAccount.list().map(\.name)
        #expect(!names.contains("root"))
        #expect(!DeviceLoginAccount.list().contains { $0.uid == 0 })
    }

    @Test func `login argv0 is a dash login name`() {
        #expect(DeviceLoginAccount.loginArgv0(shellPath: "/bin/zsh") == "-zsh")
        #expect(DeviceLoginAccount.loginArgv0(shellPath: "/bin/bash") == "-bash")
    }
}
