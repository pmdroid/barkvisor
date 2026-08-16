import Foundation
import Testing

/// Structural checks for the Linux product-proof scripts (guest smoke + SPA serve).
struct LinuxGuestScriptsTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func `linux guest smoke script exists and is executable`() throws {
        let path = repoRoot.appendingPathComponent("scripts/linux-guest-smoke.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "/api/setup/admin",
            "/api/setup/bridge/skip",
            "/api/setup/complete",
            "/api/auth/login",
            "/api/networks",
            "/api/vms",
            "DRY_RUN",
            "REAL_GUEST",
            "cloudInit",
            "portForwards",
            "sshAuthorizedKeys",
            // Host-arch cloud image default (amd64 or arm64 via uname -m)
            "ubuntu-24.04-minimal-cloudimg-",
            "_default_cloud_arch",
            "uname -m",
        ] {
            #expect(body.contains(needle), "smoke script should reference \(needle)")
        }
    }

    @Test func `linux real guest smoke wrapper exists and is executable`() throws {
        let path = repoRoot.appendingPathComponent("scripts/linux-real-guest-smoke.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.contains("REAL_GUEST=1"))
        #expect(body.contains("linux-guest-smoke.sh"))
    }

    @Test func `linux frontend serve script exists and is executable`() throws {
        let path = repoRoot.appendingPathComponent("scripts/linux-frontend-serve.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.contains("BARKVISOR_FRONTEND_DIR"))
        #expect(body.contains("bun"))
        #expect(body.contains("--verify"))
        #expect(body.contains("--install-dev"))
    }

    @Test func `install-linux SKIP_FRONTEND skips SPA even when dist exists`() throws {
        let script = repoRoot.appendingPathComponent("scripts/install-linux.sh")
        let body = try String(contentsOf: script, encoding: .utf8)
        #expect(body.contains("SKIP_FRONTEND"))
        #expect(body.contains("BARKVISOR_JOIN_CODE"))
        #expect(body.contains("barkvisor join --code"))

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            "install-skip-spa-\(UUID().uuidString)",
        )
        defer { try? FileManager.default.removeItem(at: tmp) }
        let dist = tmp.appendingPathComponent("dist")
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try "<html></html>".write(
            to: dist.appendingPathComponent("index.html"),
            atomically: true,
            encoding: .utf8,
        )
        let dummyBin = tmp.appendingPathComponent("BarkVisorApp")
        try Data("x".utf8).write(to: dummyBin)

        func run(skipFrontend: Bool) throws -> String {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script.path, dummyBin.path]
            var env = ProcessInfo.processInfo.environment
            env["DRY_RUN"] = "1"
            env["FRONTEND_DIST"] = dist.path
            env["SKIP_FRONTEND"] = skipFrontend ? "1" : "0"
            proc.environment = env
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 0, "install-linux.sh exit \(proc.terminationStatus): \(output)")
            return output
        }

        let skipped = try run(skipFrontend: true)
        #expect(skipped.contains("API only"))
        #expect(!skipped.contains("\(dist.path) →"))

        let included = try run(skipFrontend: false)
        #expect(included.contains(dist.path))
    }

    @Test func `linux install docs describe API-only join`() throws {
        let linux = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/getting-started-linux.md"),
            encoding: .utf8,
        )
        #expect(linux.contains("SKIP_FRONTEND=1"))
        #expect(linux.contains("barkvisor join --code"))
        #expect(linux.contains("BARKVISOR_JOIN_CODE"))
        #expect(linux.contains("/api/pairing/join"))
        #expect(!linux.localizedCaseInsensitiveContains("cluster"))
        #expect(!linux.localizedCaseInsensitiveContains("quorum"))

        let app = try String(
            contentsOf: repoRoot.appendingPathComponent("Sources/BarkVisorApp/main.swift"),
            encoding: .utf8,
        )
        #expect(app.contains("import ArgumentParser"))
        #expect(app.contains("struct Join"))
        #expect(app.contains("var code: String"))
        #expect(app.contains("LocalPairingJoin.post"))
    }
}
