import Foundation
import Testing

/// #377: `scripts/get-barkvisor.sh` installs Ubuntu/Debian .deb or macOS .pkg.
struct GetBarkvisorBootstrapTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var script: URL {
        repoRoot.appendingPathComponent("scripts/get-barkvisor.sh")
    }

    private func readScript() throws -> String {
        try String(contentsOf: script, encoding: .utf8)
    }

    private func run(
        args: [String] = [],
        extraEnv: [String: String] = [:],
    ) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path] + args
        proc.currentDirectoryURL = repoRoot
        var env = ProcessInfo.processInfo.environment
        extraEnv.forEach { env[$0.key] = $0.value }
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (proc.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    @Test func `script exists and is executable`() {
        #expect(FileManager.default.fileExists(atPath: script.path))
        #expect(FileManager.default.isExecutableFile(atPath: script.path))
    }

    @Test func `script stays on the appliance install channel`() throws {
        let body = try readScript()
        for needle in [
            "uname -m",
            "dpkg -i",
            "barkvisor-daemon.service",
            "barkvisor-server.service",
            "barkvisor.service",
            "installer -pkg",
            "-target /",
            "/api/health",
            "--yes",
            "inspect-then-run",
            "brew install qemu swtpm",
            "never sudo brew install",
            "Ubuntu/Debian",
            "Apple Silicon",
            "Device",
        ] {
            #expect(body.contains(needle), "bootstrap script should mention \(needle)")
        }
        #expect(!body.contains("sudo brew install qemu"))
        #expect(!body.contains("brew install barkvisor"))
        #expect(!body.contains("brew upgrade barkvisor"))
        #expect(!body.contains("HelperXPCClient"))
        #expect(!body.contains("SMJobBless"))
        #expect(!body.contains("cpuCount"))
        #expect(!body.localizedCaseInsensitiveContains("cluster"))
        #expect(!body.localizedCaseInsensitiveContains("quorum"))
        #expect(!body.contains(" node"))
        #expect(!body.contains("dnf install"))
        #expect(!body.contains(".rpm"))
    }

    @Test func `dry-run linux prints dpkg and root unit start`() throws {
        let out = try run(args: ["--dry-run", "--port", "7777"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "x86_64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "ubuntu",
        ])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        #expect(out.1.contains("DRY_RUN: dpkg -i"))
        #expect(out.1.contains("services from <release-deb>"))
        #expect(out.1.contains("/api/health"))
        #expect(out.1.contains("DRY_RUN OK"))
        #expect(!out.1.contains("brew install"))
        #expect(!out.1.contains("installer -pkg"))
    }

    @Test func `dry-run debian arm64 matches arm64 deb`() throws {
        let out = try run(args: ["--dry-run"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "aarch64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "debian",
        ])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        #expect(out.1.contains("suffix=_arm64.deb"))
        #expect(out.1.contains("dpkg -i"))
    }

    @Test func `dry-run macos prints pkg install and user brew hint`() throws {
        let out = try run(args: ["--dry-run"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Darwin",
            "BARKVISOR_BOOTSTRAP_ARCH": "arm64",
            "BARKVISOR_BOOTSTRAP_QEMU": "0",
        ])
        #expect(out.0 == 0, "dry-run exit \(out.0): \(out.1)")
        #expect(out.1.contains("installer -pkg"))
        #expect(out.1.contains("-target /"))
        #expect(out.1.contains("brew install qemu swtpm"))
        #expect(out.1.contains("never sudo brew install"))
        #expect(!out.1.contains("\nsudo brew"))
        #expect(!out.1.contains("dpkg -i"))
        #expect(out.1.contains("/api/health"))
    }

    @Test func `refuses fedora and intel mac`() throws {
        // DISTRO=fedora must fail on Ubuntu CI too: do not inherit host ID_LIKE=debian.
        let fedora = try run(args: ["--dry-run"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "x86_64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "fedora",
        ])
        #expect(fedora.0 != 0, "fedora should fail: \(fedora.1)")
        #expect(fedora.1.contains("Ubuntu/Debian"))
        #expect(fedora.1.contains("rpm/Fedora"))

        let intel = try run(args: ["--dry-run"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Darwin",
            "BARKVISOR_BOOTSTRAP_ARCH": "x86_64",
        ])
        #expect(intel.0 != 0, "intel mac should fail: \(intel.1)")
        #expect(intel.1.contains("Apple Silicon"))
    }

    @Test func `pipe without --yes is inspect-then-run`() throws {
        let out = try run(args: [], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Darwin",
            "BARKVISOR_BOOTSTRAP_ARCH": "arm64",
            "DRY_RUN": "0",
        ])
        #expect(out.0 != 0, "piped run without --yes should refuse: \(out.1)")
        #expect(out.1.contains("inspect-then-run"))
        #expect(out.1.contains("--yes"))
        #expect(!out.1.contains("dpkg -i <release"))
        #expect(!out.1.contains("installer -pkg <release"))
    }

    @Test func `checksum mismatch refuses to install`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "get-barkvisor-bad-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = tmp.appendingPathComponent("barkvisor_1.0.0_amd64.deb")
        try Data("package-bytes".utf8).write(to: pkg)
        let sha = tmp.appendingPathComponent("barkvisor_1.0.0_amd64.deb.sha256")
        try Data("0000000000000000000000000000000000000000000000000000000000000000  barkvisor_1.0.0_amd64.deb\n".utf8)
            .write(to: sha)

        let out = try run(args: ["--yes"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "x86_64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "ubuntu",
            "BARKVISOR_ASSET_URL": pkg.path,
            "BARKVISOR_CHECKSUM_URL": sha.path,
            "BARKVISOR_ASSET_NAME": pkg.lastPathComponent,
            "BARKVISOR_RELEASE_TAG": "v1.0.0",
            "BARKVISOR_BOOTSTRAP_TMPDIR": tmp.appendingPathComponent("work").path,
            "BARKVISOR_BOOTSTRAP_SKIP_INSTALL": "1",
            "BARKVISOR_BOOTSTRAP_SKIP_HEALTH": "1",
        ])
        #expect(out.0 != 0, "mismatch should fail: \(out.1)")
        #expect(out.1.contains("checksum mismatch"))
        #expect(!out.1.contains("SKIP_INSTALL: dpkg"))
    }

    @Test func `checksum match installs linux unit then health poll fails closed`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "get-barkvisor-ok-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = tmp.appendingPathComponent("barkvisor_1.0.0_amd64.deb")
        try Data("package-bytes".utf8).write(to: pkg)
        let digest = try sha256Hex(of: pkg)
        let sha = tmp.appendingPathComponent("barkvisor_1.0.0_amd64.deb.sha256")
        try Data("\(digest)  barkvisor_1.0.0_amd64.deb\n".utf8).write(to: sha)

        let out = try run(args: ["--yes", "--port", "59999"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "amd64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "debian",
            "BARKVISOR_ASSET_URL": pkg.path,
            "BARKVISOR_CHECKSUM_URL": sha.path,
            "BARKVISOR_ASSET_NAME": pkg.lastPathComponent,
            "BARKVISOR_RELEASE_TAG": "v1.0.0",
            "BARKVISOR_BOOTSTRAP_TMPDIR": tmp.appendingPathComponent("work").path,
            "BARKVISOR_BOOTSTRAP_SKIP_INSTALL": "1",
            "BARKVISOR_HEALTH_ATTEMPTS": "2",
            "BARKVISOR_HEALTH_SLEEP": "0.1",
        ])
        #expect(out.0 != 0, "dead health port should fail: \(out.1)")
        #expect(out.1.contains("checksum OK"))
        #expect(out.1.contains("SKIP_INSTALL: dpkg -i"))
        #expect(out.1.contains("SKIP_INSTALL: service activation"))
        #expect(out.1.contains("did not answer"))
        #expect(out.1.contains("/api/health"))
        #expect(!out.1.contains("cluster"))
    }

    @Test func `macos path uses installer and does not brew the app`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "get-barkvisor-pkg-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = tmp.appendingPathComponent("BarkVisor-1.0.0.pkg")
        try Data("pkg-bytes".utf8).write(to: pkg)
        let digest = try sha256Hex(of: pkg)
        let sha = tmp.appendingPathComponent("BarkVisor-1.0.0.pkg.sha256")
        try Data("\(digest)  BarkVisor-1.0.0.pkg\n".utf8).write(to: sha)

        let out = try run(args: ["--yes"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Darwin",
            "BARKVISOR_BOOTSTRAP_ARCH": "arm64",
            "BARKVISOR_BOOTSTRAP_QEMU": "0",
            "BARKVISOR_ASSET_URL": pkg.path,
            "BARKVISOR_CHECKSUM_URL": sha.path,
            "BARKVISOR_ASSET_NAME": pkg.lastPathComponent,
            "BARKVISOR_RELEASE_TAG": "v1.0.0",
            "BARKVISOR_BOOTSTRAP_TMPDIR": tmp.appendingPathComponent("work").path,
            "BARKVISOR_BOOTSTRAP_SKIP_INSTALL": "1",
            "BARKVISOR_BOOTSTRAP_SKIP_HEALTH": "1",
        ])
        #expect(out.0 == 0, "macos skip-install exit \(out.0): \(out.1)")
        #expect(out.1.contains("SKIP_INSTALL: installer -pkg"))
        #expect(out.1.contains("-target /"))
        #expect(out.1.contains("brew install qemu swtpm"))
        #expect(!out.1.contains("brew install barkvisor"))
        #expect(!out.1.contains("\nsudo brew"))
    }

    @Test func `release json picks matching deb and sidecar`() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "get-barkvisor-api-\(UUID().uuidString)",
        )
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pkg = tmp.appendingPathComponent("barkvisor_9.9.9_arm64.deb")
        try Data("arm-deb".utf8).write(to: pkg)
        let digest = try sha256Hex(of: pkg)
        let sha = tmp.appendingPathComponent("barkvisor_9.9.9_arm64.deb.sha256")
        try Data("\(digest)  barkvisor_9.9.9_arm64.deb\n".utf8).write(to: sha)

        let releases = tmp.appendingPathComponent("releases.json")
        let json = """
        [{"tag_name":"v9.9.9","prerelease":true,"assets":[
          {"name":"\(pkg.lastPathComponent)","browser_download_url":"\(pkg.path)"},
          {"name":"\(sha.lastPathComponent)","browser_download_url":"\(sha.path)"}
        ]}]
        """
        try Data(json.utf8).write(to: releases)

        let out = try run(args: ["--yes"], extraEnv: [
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "arm64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "ubuntu",
            "BARKVISOR_RELEASES_URL": releases.path,
            "BARKVISOR_BOOTSTRAP_TMPDIR": tmp.appendingPathComponent("work").path,
            "BARKVISOR_BOOTSTRAP_SKIP_INSTALL": "1",
            "BARKVISOR_BOOTSTRAP_SKIP_HEALTH": "1",
        ])
        #expect(out.0 == 0, "api pick exit \(out.0): \(out.1)")
        #expect(out.1.contains("release v9.9.9"))
        #expect(out.1.contains("barkvisor_9.9.9_arm64.deb"))
        #expect(out.1.contains("checksum OK"))
    }

    @Test func `legacy deb starts only combined console service`() throws {
        let out = try installWithUnits(["barkvisor.service", "barkvisor-agent.service"])
        #expect(out.0 == 0, "legacy install failed: \(out.1)")
        #expect(out.1.contains("SYSTEMCTL: enable --now barkvisor.service\n"))
        #expect(!out.1.contains("enable --now barkvisor-agent.service"))
        #expect(!out.1.contains("enable --now barkvisor-daemon.service"))
        #expect(out.1.contains("Open http://localhost:58888 to finish setup."))
    }

    @Test func `split deb starts daemon and server and disables combined modes`() throws {
        let out = try installWithUnits([
            "barkvisor.service", "barkvisor-agent.service",
            "barkvisor-daemon.service", "barkvisor-server.service",
        ])
        #expect(out.0 == 0, "split install failed: \(out.1)")
        #expect(out.1.contains("SYSTEMCTL: disable --now barkvisor.service\n"))
        #expect(out.1.contains("SYSTEMCTL: disable --now barkvisor-agent.service\n"))
        #expect(out.1.contains("SYSTEMCTL: enable --now barkvisor-daemon.service barkvisor-server.service\n"))
        #expect(!out.1.contains("enable --now barkvisor.service"))
        #expect(!out.1.contains("enable --now barkvisor-agent.service"))
    }

    @Test func `split deb selects packaged services despite stale installed combined unit`() throws {
        let out = try installWithUnits(["barkvisor-daemon.service", "barkvisor-server.service"])
        #expect(out.0 == 0, "split install failed: \(out.1)")
        #expect(out.1.contains("SYSTEMCTL: enable --now barkvisor-daemon.service barkvisor-server.service\n"))
        #expect(!out.1.contains("enable --now barkvisor.service"))
    }

    @Test func `incomplete split deb refuses to activate legacy services`() throws {
        let out = try installWithUnits(["barkvisor.service", "barkvisor-daemon.service"])
        #expect(out.0 != 0, "incomplete package must fail: \(out.1)")
        #expect(!out.1.contains("SYSTEMCTL: enable --now"))
    }

    private func installWithUnits(_ units: [String]) throws -> (Int32, String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bootstrap-units-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let bin = tmp.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let mocks = [
            "dpkg-deb": "printf '%s\\n' \"$BOOTSTRAP_UNIT_FILES\"\n",
            "dpkg": "printf 'DPKG: %s\\n' \"$*\"\n",
            "id": "printf '0\\n'\n",
            "systemctl": "if [ \"$1\" = cat ]; then exit 0; fi\nprintf 'SYSTEMCTL: %s\\n' \"$*\"\n",
        ]
        for (name, body) in mocks {
            let file = bin.appendingPathComponent(name)
            try Data(body.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        let pkg = tmp.appendingPathComponent("barkvisor_1.0.0_amd64.deb")
        try Data("package-bytes".utf8).write(to: pkg)
        let sha = tmp.appendingPathComponent("\(pkg.lastPathComponent).sha256")
        try Data("\(try sha256Hex(of: pkg))  \(pkg.lastPathComponent)\n".utf8).write(to: sha)
        return try run(args: ["--yes", "--port", "58888"], extraEnv: [
            "PATH": "\(bin.path):\(ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")",
            "BOOTSTRAP_UNIT_FILES": units.map { "-rw-r--r-- root/root 0 2026-01-01 00:00 ./lib/systemd/system/\($0)" }.joined(separator: "\n"),
            "BARKVISOR_BOOTSTRAP_OS": "Linux",
            "BARKVISOR_BOOTSTRAP_ARCH": "amd64",
            "BARKVISOR_BOOTSTRAP_DISTRO": "debian",
            "BARKVISOR_ASSET_URL": pkg.path,
            "BARKVISOR_CHECKSUM_URL": sha.path,
            "BARKVISOR_BOOTSTRAP_TMPDIR": tmp.appendingPathComponent("work").path,
            "BARKVISOR_BOOTSTRAP_SKIP_INSTALL": "0",
            "BARKVISOR_BOOTSTRAP_SKIP_HEALTH": "1",
        ])
    }

    private func sha256Hex(of file: URL) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "shasum -a 256 \"$1\" | awk '{print $1}'", "shasum", file.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "shasum failed: \(text)")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
