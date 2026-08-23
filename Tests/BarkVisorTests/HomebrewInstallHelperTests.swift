import Foundation
import Testing

/// PAS-292: optional privileged helper copy for Homebrew. NAT does not need it.
struct HomebrewInstallHelperTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(relative),
            encoding: .utf8,
        )
    }

    @Test func `install helper copies signed binary and MachServices plist`() throws {
        let script = try read("packaging/homebrew/barkvisor-install-helper")
        #expect(script.contains("PrivilegedHelperTools"))
        #expect(script.contains("LaunchDaemons"))
        #expect(script.contains("dev.barkvisor.helper"))
        #expect(script.contains("codesign --verify --strict"))
        #expect(script.contains("MachServices"))
        #expect(script.contains("NAT Workloads"))
        #expect(script.contains("launchctl bootstrap"))
        #expect(script.contains("HELPER_SRC"))
        #expect(script.contains("DEST_ROOT"))
        #expect(!script.contains("brew services start"))
        #expect(!script.contains("homebrew.mxcl"))

        let plist = try read("packaging/homebrew/dev.barkvisor.helper.plist")
        #expect(plist.contains("<key>MachServices</key>"))
        #expect(plist.contains("<key>dev.barkvisor.helper</key>"))
        #expect(plist.contains("<string>/Library/PrivilegedHelperTools/dev.barkvisor.helper</string>"))
        #expect(plist.contains("<key>Program</key>"))
        #expect(!plist.contains("BundleProgram"))
        #expect(!plist.contains("homebrew.mxcl"))
    }

    @Test func `formula ships keg helper without brew services loading it`() throws {
        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(formula.contains("--product\", \"BarkVisorHelper\""))
        #expect(formula.contains("libexec.install helper => \"dev.barkvisor.helper\""))
        #expect(formula.contains("bin.install buildpath/\"packaging/homebrew/barkvisor-install-helper\""))
        #expect(formula.contains("--identifier\", \"dev.barkvisor.app\""))
        #expect(formula.contains("bin/\"barkvisor\""))
        #expect(formula.contains("libexec/\"dev.barkvisor.helper\""))
        #expect(formula.contains("codesign\", \"--verify\", \"--strict\""))
        #expect(formula.contains("dev.barkvisor.helper.plist"))
        #expect(formula.contains("NAT Workloads work without the privileged helper"))
        #expect(formula.contains("sudo #{opt_bin}/barkvisor-install-helper"))
        #expect(formula.contains("assert_path_exists bin/\"barkvisor-install-helper\""))
        #expect(formula.contains("assert_path_exists libexec/\"dev.barkvisor.helper\""))
        #expect(!formula.contains("launchctl bootstrap system /Library/LaunchDaemons/dev.barkvisor.helper"))

        let daemonPlist = try read("packaging/homebrew/homebrew.mxcl.barkvisor.plist")
        #expect(!daemonPlist.contains("PrivilegedHelperTools"))
        #expect(!daemonPlist.contains("MachServices"))

        let postinstall = try read("packaging/homebrew/postinstall.sh")
        #expect(!postinstall.contains("dev.barkvisor.helper"))
        #expect(!postinstall.contains("PrivilegedHelperTools"))
    }

    @Test func `operator docs say NAT works without the helper`() throws {
        let homebrew = try read("docs/getting-started-homebrew.md")
        #expect(homebrew.contains("## Requirements"))
        #expect(homebrew.contains("depends_on arch: :arm64"))
        #expect(homebrew.contains("/opt/homebrew"))
        #expect(homebrew.contains("/var/lib/barkvisor"))
        #expect(homebrew.contains("brew upgrade barkvisor"))
        #expect(homebrew.contains("sudo brew services restart barkvisor"))
        #expect(homebrew.contains("log stream"))
        #expect(homebrew.contains("barkvisor-install-helper"))
        #expect(homebrew.contains("/Library/PrivilegedHelperTools"))
        #expect(homebrew.contains("MachServices") || homebrew.contains("dev.barkvisor.helper"))
        #expect(homebrew.contains("Do not mix"))
        #expect(homebrew.contains("port 7777"))
        #expect(homebrew.contains("sudo rm -rf /var/lib/barkvisor"))
        #expect(homebrew.localizedCaseInsensitiveContains("NAT"))
        #expect(homebrew.contains("Home"))
        #expect(homebrew.contains("Device"))
        #expect(homebrew.contains("Workload"))
        #expect(!homebrew.localizedCaseInsensitiveContains("cluster"))
        #expect(!homebrew.localizedCaseInsensitiveContains("quorum"))

        let packaging = try read("packaging/homebrew/README.md")
        #expect(packaging.contains("barkvisor-install-helper"))
        #expect(packaging.contains("NAT"))
        #expect(packaging.contains("PrivilegedHelperTools"))

        let installation = try read("docs/getting-started-installation.md")
        #expect(installation.contains("getting-started-homebrew.md"))

        let linux = try read("docs/getting-started-linux.md")
        #expect(linux.contains("getting-started-homebrew.md"))

        let firstLaunch = try read("docs/getting-started-first-launch.md")
        #expect(firstLaunch.contains("barkvisor-install-helper"))
        #expect(firstLaunch.contains("sudo brew services stop barkvisor"))

        let quickstart = try read("docs/getting-started-quickstart.md")
        #expect(quickstart.contains("getting-started-homebrew.md"))

        let troubleshooting = try read("docs/getting-started-troubleshooting.md")
        #expect(troubleshooting.contains("barkvisor-install-helper"))

        let readme = try read("README.md")
        #expect(readme.contains("getting-started-homebrew.md"))
    }

    @Test func `website syncs Homebrew docs into the sidebar`() throws {
        let sync = try read("website/scripts/sync-content.mjs")
        #expect(sync.contains("getting-started-homebrew.md"))
        #expect(sync.contains("getting-started/homebrew.md"))
        #expect(sync.contains("getting-started-homebrew\\.md"))

        let sidebar = try read("website/astro.config.mjs")
        #expect(sidebar.contains("/docs/getting-started/homebrew/"))

        let index = try read("website/src/content/docs/docs/index.mdx")
        #expect(index.contains("/docs/getting-started/homebrew/"))
    }

    #if os(macOS)
        @Test func `install helper copies into DEST_ROOT without launchctl`() throws {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("bv-helper-\(UUID().uuidString)", isDirectory: true)
            let helperSrc = dest.appendingPathComponent("signed-helper")
            defer { try? FileManager.default.removeItem(at: dest) }

            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            let compile = Process()
            compile.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compile.arguments = ["-o", helperSrc.path, "-x", "c", "-"]
            let pipe = Pipe()
            compile.standardInput = pipe
            try compile.run()
            try pipe.fileHandleForWriting.write(contentsOf: Data("int main(void) { return 0; }\n".utf8))
            try pipe.fileHandleForWriting.close()
            compile.waitUntilExit()
            #expect(compile.terminationStatus == 0)

            let sign = Process()
            sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            sign.arguments = ["--force", "--sign", "-", helperSrc.path]
            try sign.run()
            sign.waitUntilExit()
            #expect(sign.terminationStatus == 0)

            let script = repoRoot.appendingPathComponent("packaging/homebrew/barkvisor-install-helper")
            let plist = repoRoot.appendingPathComponent(
                "packaging/homebrew/dev.barkvisor.helper.plist",
            )
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/bin/bash")
            install.arguments = [script.path]
            install.environment = [
                "PATH": "/usr/bin:/bin",
                "DEST_ROOT": dest.path,
                "HELPER_SRC": helperSrc.path,
                "HELPER_PLIST": plist.path,
                "SKIP_LAUNCHCTL": "1",
            ]
            let out = Pipe()
            install.standardOutput = out
            install.standardError = out
            try install.run()
            install.waitUntilExit()
            let log = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(install.terminationStatus == 0, "install helper failed: \(log)")

            let copied = dest.appendingPathComponent("Library/PrivilegedHelperTools/dev.barkvisor.helper")
            let written = dest.appendingPathComponent("Library/LaunchDaemons/dev.barkvisor.helper.plist")
            #expect(FileManager.default.isExecutableFile(atPath: copied.path))
            let writtenPlist = try String(contentsOf: written, encoding: .utf8)
            #expect(writtenPlist.contains("<key>MachServices</key>"))
            #expect(writtenPlist.contains("/Library/PrivilegedHelperTools/dev.barkvisor.helper"))
        }

        @Test func `install helper refuses an unsigned binary`() throws {
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("bv-helper-unsigned-\(UUID().uuidString)", isDirectory: true)
            let helperSrc = dest.appendingPathComponent("unsigned-helper")
            defer { try? FileManager.default.removeItem(at: dest) }

            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try Data("not a signed helper\n".utf8).write(to: helperSrc)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperSrc.path)

            let script = repoRoot.appendingPathComponent("packaging/homebrew/barkvisor-install-helper")
            let plist = repoRoot.appendingPathComponent(
                "packaging/homebrew/dev.barkvisor.helper.plist",
            )
            let install = Process()
            install.executableURL = URL(fileURLWithPath: "/bin/bash")
            install.arguments = [script.path]
            install.environment = [
                "PATH": "/usr/bin:/bin",
                "DEST_ROOT": dest.path,
                "HELPER_SRC": helperSrc.path,
                "HELPER_PLIST": plist.path,
                "SKIP_LAUNCHCTL": "1",
            ]
            let out = Pipe()
            install.standardOutput = out
            install.standardError = out
            try install.run()
            install.waitUntilExit()
            #expect(install.terminationStatus != 0)
            let copied = dest.appendingPathComponent("Library/PrivilegedHelperTools/dev.barkvisor.helper")
            #expect(!FileManager.default.fileExists(atPath: copied.path))
        }
    #endif
}
