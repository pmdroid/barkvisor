import Foundation
import Testing
@testable import BarkVisorCore

struct WorkloadPrivilegeDropTests {
    private let qemu = URL(fileURLWithPath: "/usr/bin/qemu-system-aarch64")
    private let args = ["-uuid", "test"]

    @Test func `macos never drops even when euid is 0`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 0,
            dropsOnPlatform: false,
            userExists: { _ in true },
            wrapperPath: { $0 },
        )
        #expect(!launch.dropped)
        #expect(launch.executable == qemu)
        #expect(launch.arguments == args)
        #expect(launch.reason.contains("HVF"))
        #expect(launch.reason.contains("USB"))
    }

    @Test func `linux non-root inherits current uid`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 501,
            dropsOnPlatform: true,
            userExists: { $0 == "barkvisor" },
            wrapperPath: { $0 == WorkloadPrivilegeDrop.setprivPath ? $0 : nil },
        )
        #expect(!launch.dropped)
        #expect(launch.reason.contains("not root"))
    }

    @Test func `linux root prefers barkvisor via setpriv`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 0,
            dropsOnPlatform: true,
            userExists: { $0 == "barkvisor" || $0 == "qemu" },
            wrapperPath: { $0 == WorkloadPrivilegeDrop.setprivPath ? $0 : nil },
        )
        #expect(launch.dropped)
        #expect(launch.user == "barkvisor")
        #expect(launch.executable.path == WorkloadPrivilegeDrop.setprivPath)
        #expect(launch.arguments == [
            "--reuid=barkvisor",
            "--regid=barkvisor",
            "--init-groups",
            "--inh-caps=-all",
            "--",
            qemu.path,
            "-uuid",
            "test",
        ])
    }

    @Test func `linux root falls back to qemu user`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 0,
            dropsOnPlatform: true,
            userExists: { $0 == "qemu" },
            wrapperPath: { $0 == WorkloadPrivilegeDrop.setprivPath ? $0 : nil },
        )
        #expect(launch.dropped)
        #expect(launch.user == "qemu")
        #expect(launch.arguments.contains("--reuid=qemu"))
    }

    @Test func `linux root uses runuser when setpriv is missing`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 0,
            dropsOnPlatform: true,
            userExists: { $0 == "barkvisor" },
            wrapperPath: { $0 == "/usr/sbin/runuser" ? $0 : nil },
        )
        #expect(launch.dropped)
        #expect(launch.executable.path == "/usr/sbin/runuser")
        #expect(launch.arguments == ["-u", "barkvisor", "--", qemu.path, "-uuid", "test"])
    }

    @Test func `linux root without wrapper inherits uid 0`() {
        let launch = WorkloadPrivilegeDrop.plan(
            executable: qemu,
            arguments: args,
            euid: 0,
            dropsOnPlatform: true,
            userExists: { $0 == "barkvisor" },
            wrapperPath: { _ in nil },
        )
        #expect(!launch.dropped)
        #expect(launch.reason.contains("setpriv/runuser missing"))
    }

    @Test func `setpriv-wrapped argv still parses as qemu`() {
        let wrapped = WorkloadPrivilegeDrop.setprivArguments(
            user: "barkvisor",
            executable: qemu,
            arguments: ["-uuid", "6FB33A30-F139-4DE5-80EB-1DA1883696B1"],
        )
        let argv = QEMUArgv(arguments: [WorkloadPrivilegeDrop.setprivPath] + wrapped)
        #expect(argv?.uuid == "6FB33A30-F139-4DE5-80EB-1DA1883696B1")
    }

    @Test func `live apply on this host does not invent a drop user`() {
        let launch = WorkloadPrivilegeDrop.apply(executable: qemu, arguments: args)
        #expect(launch.executable.path.hasPrefix("/"))
        if !WorkloadPrivilegeDrop.dropsOnThisPlatform {
            #expect(!launch.dropped)
        }
        if WorkloadPrivilegeDrop.currentEUID() != 0 {
            #expect(!launch.dropped)
        }
    }
}
