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

    @Test func `guest-boot feature maps blank and real smoke scripts`() throws {
        let path = repoRoot.appendingPathComponent("features/guest-boot.feature").path
        #expect(FileManager.default.fileExists(atPath: path))
        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "a blank-disk Workload reaches running",
            "a Linux Workload boots from a cloud image and answers SSH",
            "linux-guest-smoke.sh",
            "linux-real-guest-smoke.sh",
            "mise run guest-smoke",
            "Workload",
            "Device",
            "Library",
        ] {
            #expect(body.contains(needle), "feature should mention \(needle)")
        }
        #expect(!body.localizedCaseInsensitiveContains("cluster"))
        #expect(!body.localizedCaseInsensitiveContains("quorum"))
        #expect(!body.contains("Scenario: a Windows"))
    }

    @Test func `guest-boot mapper exists and dry-run succeeds`() throws {
        let path = repoRoot.appendingPathComponent("scripts/guest-boot-bdd.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "linux-guest-smoke.sh",
            "linux-real-guest-smoke.sh",
            "SKIP: qemu-system-*",
            "ALLOW_NO_QEMU",
            "BDD_FORCE_NO_QEMU",
            "features/guest-boot.feature",
        ] {
            #expect(body.contains(needle), "mapper should reference \(needle)")
        }

        func run(args: [String], extraEnv: [String: String] = [:]) throws -> (Int32, String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [path] + args
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

        let dry = try run(args: [], extraEnv: ["DRY_RUN": "1"])
        #expect(dry.0 == 0, "DRY_RUN exit \(dry.0): \(dry.1)")
        #expect(dry.1.contains("a blank-disk Workload reaches running"))
        #expect(dry.1.contains("a Linux Workload boots from a cloud image and answers SSH"))
        #expect(dry.1.contains("DRY_RUN OK"))

        let listed = try run(args: ["list"])
        #expect(listed.0 == 0, "list exit \(listed.0): \(listed.1)")
        #expect(listed.1.contains("a blank-disk Workload reaches running"))
        #expect(listed.1.contains("a Linux Workload boots from a cloud image and answers SSH"))

        let skipped = try run(args: ["blank"], extraEnv: ["BDD_FORCE_NO_QEMU": "1"])
        #expect(skipped.0 == 0, "skip exit \(skipped.0): \(skipped.1)")
        #expect(skipped.1.contains("SKIP: qemu-system-* is not on PATH"))
        #expect(skipped.1.contains("a blank-disk Workload reaches running"))
    }

    @Test func `mise guest-smoke tasks are opt-in and not in default prepush`() throws {
        let mise = try String(
            contentsOf: repoRoot.appendingPathComponent("mise.toml"),
            encoding: .utf8,
        )
        #expect(mise.contains("[tasks.guest-smoke]"))
        #expect(mise.contains("[tasks.guest-smoke-real]"))
        #expect(mise.contains("[tasks.prepush-full]"))
        #expect(mise.contains("guest-boot-bdd.sh blank"))
        #expect(mise.contains("guest-boot-bdd.sh real"))

        // Default prepush must stay lint + test + frontend-test (no guest boot).
        #expect(mise.contains("depends = [\"lint\", \"test\", \"frontend-test\"]"))
        #expect(!mise.contains("depends = [\"lint\", \"test\", \"frontend-test\", \"guest-smoke\"]"))
        let start = try #require(mise.range(of: "[tasks.prepush]\n"))
        let after = mise[start.upperBound...]
        let nextHeader = after.range(of: "\n[tasks.")
        let prepushBlock = nextHeader.map { after[..<$0.lowerBound] } ?? after[...]
        #expect(!String(prepushBlock).contains("guest-smoke"))

        let docs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/getting-started-development.md"),
            encoding: .utf8,
        )
        #expect(docs.contains("mise run guest-smoke"))
        #expect(docs.contains("TCG"))
        #expect(docs.contains("~15 min") || docs.contains("~15 minutes"))
        #expect(docs.contains("KVM"))
        #expect(!docs.localizedCaseInsensitiveContains("cluster"))
        #expect(!docs.localizedCaseInsensitiveContains("quorum"))
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
