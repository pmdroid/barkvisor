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

    /// Body of a `[tasks.NAME]` table until the next TOML header.
    private func miseTaskTable(_ mise: String, name: String) -> String? {
        guard let header = mise.range(of: "[tasks.\(name)]") else { return nil }
        let rest = mise[header.upperBound...]
        if let next = rest.range(of: "\n[") {
            return String(rest[..<next.lowerBound])
        }
        return String(rest)
    }

    private func quotedStrings(in text: String) -> [String] {
        var out: [String] = []
        var remaining = text[...]
        while let start = remaining.firstIndex(of: "\"") {
            let afterStart = remaining.index(after: start)
            guard let end = remaining[afterStart...].firstIndex(of: "\"") else { break }
            out.append(String(remaining[afterStart ..< end]))
            remaining = remaining[remaining.index(after: end)...]
        }
        return out
    }

    /// `depends = [...]` entries in a mise task table, whitespace-insensitive.
    private func miseDepends(in table: String) -> [String] {
        guard let key = table.range(of: "depends") else { return [] }
        let afterKey = table[key.upperBound...]
        guard let open = afterKey.firstIndex(of: "["),
              let close = afterKey[open...].firstIndex(of: "]")
        else { return [] }
        return quotedStrings(in: String(afterKey[open ... close]))
    }

    private func defaultPrepushDepends(_ mise: String) -> Set<String> {
        guard let table = miseTaskTable(mise, name: "prepush") else { return [] }
        return Set(miseDepends(in: table))
    }

    @Test func `linux guest smoke script exists and is executable`() throws {
        let path = repoRoot.appendingPathComponent("scripts/linux-guest-smoke.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "/api/setup/admin",
            "/api/setup/bridge/skip",
            "/api/setup/library",
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

    @Test func `headless setup puts library before complete`() throws {
        let path = repoRoot.appendingPathComponent("scripts/lib/linux-smoke-common.sh").path
        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.contains("GET /api/setup/library"))
        #expect(body.contains("api_code PUT /api/setup/library"))
        let putRange = try #require(body.range(of: "api_code PUT /api/setup/library"))
        let completeRange = try #require(body.range(of: "POST /api/setup/complete"))
        #expect(putRange.lowerBound < completeRange.lowerBound)
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

        // No args must print help, not start a server / QEMU.
        let help = try run(args: [], extraEnv: ["DRY_RUN": "0"])
        #expect(help.0 == 0, "help exit \(help.0): \(help.1)")
        #expect(help.1.contains("Usage:"))
        #expect(!help.1.contains("Scenario:"))

        // Parent ALLOW_NO_QEMU=1 would take the create-only API branch.
        let skipEnv = ["BDD_FORCE_NO_QEMU": "1", "ALLOW_NO_QEMU": "0"]
        let skipped = try run(args: ["blank"], extraEnv: skipEnv)
        #expect(skipped.0 == 0, "skip exit \(skipped.0): \(skipped.1)")
        #expect(skipped.1.contains("SKIP: qemu-system-* is not on PATH"))
        #expect(skipped.1.contains("a blank-disk Workload reaches running"))

        let skippedAll = try run(args: ["all"], extraEnv: skipEnv)
        #expect(skippedAll.0 == 0, "all skip exit \(skippedAll.0): \(skippedAll.1)")
        #expect(skippedAll.1.contains("a blank-disk Workload reaches running"))
        #expect(skippedAll.1.contains("a Linux Workload boots from a cloud image and answers SSH"))
        let skipCount = skippedAll.1.components(separatedBy: "SKIP: qemu-system-* is not on PATH").count - 1
        #expect(skipCount == 2, "all should skip both scenarios when QEMU is absent: \(skippedAll.1)")
    }

    @Test func `api-contract BDD mapper exists and dry-run succeeds`() throws {
        let path = repoRoot.appendingPathComponent("scripts/api-contract-bdd.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))
        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "features/api-contract.feature",
            "api-contract-probe.py",
            "docs/api/openapi.yaml",
            "DRY_RUN",
            "export BASE=",
            "API_BDD_USB",
        ] {
            #expect(body.contains(needle), "api-bdd should reference \(needle)")
        }
        let probe = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/lib/api-contract-probe.py"),
            encoding: .utf8,
        )
        #expect(probe.contains("BARKVISOR_PORT"))
        #expect(probe.contains("API_BDD_USB"))
        #expect(probe.contains("USB attach needs host hardware"))
        #expect(!probe.contains("\"deviceId\": \"0000:0000\""))
        let feature = try String(
            contentsOf: repoRoot.appendingPathComponent("features/api-contract.feature"),
            encoding: .utf8,
        )
        #expect(feature.contains("every documented API operation is probed"))
        #expect(!feature.localizedCaseInsensitiveContains("cluster"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [path]
        proc.currentDirectoryURL = repoRoot
        var env = ProcessInfo.processInfo.environment
        env["DRY_RUN"] = "1"
        proc.environment = env
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        #expect(proc.terminationStatus == 0, "DRY_RUN exit \(proc.terminationStatus): \(out)")
        #expect(out.contains("DRY_RUN OK"))
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
        #expect(mise.contains("[tasks.api-bdd]"))
        #expect(mise.contains("api-contract-bdd.sh"))
        #expect(mise.contains("[tasks.host-network-extra-ip]"))
        #expect(mise.contains("linux-host-network-docker.sh"))

        // Default prepush must stay lint + test + frontend-test (no guest boot).
        let prepushDeps = defaultPrepushDepends(mise)
        #expect(prepushDeps == ["lint", "test", "frontend-test"])
        let prepushTable = try #require(miseTaskTable(mise, name: "prepush"))
        #expect(!prepushTable.contains("guest-smoke"))
        #expect(!prepushTable.contains("host-network-extra-ip"))

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

    @Test func `cross-device feature names Home proxy create and start`() throws {
        let path = repoRoot.appendingPathComponent("features/cross-device.feature").path
        #expect(FileManager.default.fileExists(atPath: path))
        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "a Workload created from the Home runs on a paired Device",
            "cross-device-smoke.sh",
            "mise run cross-device-smoke",
            "/api/pairing/codes",
            "/api/pairing/join",
            "/api/home/devices/health",
            "/api/home/devices/:id/v1",
            "Home",
            "Device",
            "Workload",
            "Library",
        ] {
            #expect(body.contains(needle), "feature should mention \(needle)")
        }
        #expect(!body.localizedCaseInsensitiveContains("cluster"))
        #expect(!body.localizedCaseInsensitiveContains("quorum"))
        #expect(!body.localizedCaseInsensitiveContains("node"))
        #expect(!body.localizedCaseInsensitiveContains("re-pair"))
        #expect(!body.contains("PAS-77"))
    }

    @Test func `cross-device smoke exists and dry-run succeeds`() throws {
        let path = repoRoot.appendingPathComponent("scripts/cross-device-smoke.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "linux-smoke-common.sh",
            "/api/pairing/codes",
            "/api/pairing/join",
            "/api/home/devices/health",
            "/v1/vms",
            "BARKVISOR_DATA_DIR",
            "BARKVISOR_AGENT_PORT",
            "pick_free_port",
            "features/cross-device.feature",
            "DRY_RUN",
        ] {
            #expect(body.contains(needle), "smoke script should reference \(needle)")
        }
        #expect(!body.localizedCaseInsensitiveContains("cluster"))
        #expect(!body.localizedCaseInsensitiveContains("quorum"))
        #expect(!body.contains("PAS-77"))

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
        #expect(dry.1.contains("a Workload created from the Home runs on a paired Device"))
        #expect(dry.1.contains("/api/pairing/codes"))
        #expect(dry.1.contains("/api/home/devices/health"))
        #expect(dry.1.contains("DRY_RUN OK"))

        let listed = try run(args: ["list"])
        #expect(listed.0 == 0, "list exit \(listed.0): \(listed.1)")
        #expect(listed.1.contains("a Workload created from the Home runs on a paired Device"))
    }

    @Test func `mise cross-device-smoke is opt-in and not in default prepush`() throws {
        let mise = try String(
            contentsOf: repoRoot.appendingPathComponent("mise.toml"),
            encoding: .utf8,
        )
        #expect(mise.contains("[tasks.cross-device-smoke]"))
        #expect(mise.contains("cross-device-smoke.sh"))
        let prepushDeps = defaultPrepushDepends(mise)
        #expect(prepushDeps == ["lint", "test", "frontend-test"])
        let prepushTable = try #require(miseTaskTable(mise, name: "prepush"))
        #expect(!prepushTable.contains("cross-device-smoke"))

        let docs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/getting-started-development.md"),
            encoding: .utf8,
        )
        #expect(docs.contains("mise run cross-device-smoke"))
        #expect(docs.contains("/api/pairing/codes"))
        #expect(docs.contains("/api/home/devices/:id/v1"))
        #expect(!docs.localizedCaseInsensitiveContains("cluster"))
        #expect(!docs.localizedCaseInsensitiveContains("quorum"))
    }

    @Test func `features directory only contains mapped gherkin`() throws {
        let dir = repoRoot.appendingPathComponent("features")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".feature") }
            .sorted()
        #expect(names == [
            "api-contract.feature",
            "cross-device.feature",
            "guest-boot.feature",
            "host-network-extra-ip.feature",
        ])
    }

    @Test func `packages ship barkvisor and barkvisor-agent`() throws {
        let stage = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/lib/linux-package-stage.sh"),
            encoding: .utf8,
        )
        #expect(stage.contains("ln -s barkvisor"))
        #expect(stage.contains("barkvisor-agent.service"))

        let home = try String(
            contentsOf: repoRoot.appendingPathComponent("packaging/linux/barkvisor.service"),
            encoding: .utf8,
        )
        let agent = try String(
            contentsOf: repoRoot.appendingPathComponent("packaging/linux/barkvisor-agent.service"),
            encoding: .utf8,
        )
        #expect(home.contains("ExecStart=/usr/local/bin/barkvisor\n"))
        #expect(home.contains("Conflicts=barkvisor-agent.service"))
        #expect(agent.contains("ExecStart=/usr/local/bin/barkvisor-agent\n"))
        #expect(agent.contains("Conflicts=barkvisor.service"))

        let rpm = try String(
            contentsOf: repoRoot.appendingPathComponent("packaging/linux/rpm/barkvisor.spec.in"),
            encoding: .utf8,
        )
        #expect(rpm.contains("/usr/local/bin/barkvisor-agent"))
        #expect(rpm.contains("/usr/lib/systemd/system/barkvisor-agent.service"))
    }

    @Test func `linux install docs describe API-only join`() throws {
        let linux = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/getting-started-linux.md"),
            encoding: .utf8,
        )
        #expect(linux.contains("SKIP_FRONTEND=1"))
        #expect(linux.contains("barkvisor-agent.service"))
        #expect(linux.contains("barkvisor join --code"))
        #expect(linux.contains("barkvisor-agent join --code"))
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
        #expect(app.contains("struct Doctor"))
        #expect(app.contains("DoctorService.probe"))
        #expect(app.contains("var code: String"))
        #expect(app.contains("LocalPairingJoin.post"))
        #expect(app.contains("http://127.0.0.1:7777/api/pairing/join"))
        #expect(app.contains("not the short printed code"))
        #expect(app.contains("Full barkvisor://pair/v1?"))
    }

    @Test func `guest-boot CI helper probes kvm and skips without it`() throws {
        let path = repoRoot.appendingPathComponent("scripts/ci-guest-boot.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        for needle in [
            "guest-boot-bdd.sh",
            "REQUIRE_KVM",
            "CI_FORCE_NO_KVM",
            "/dev/kvm",
            "SKIP: /dev/kvm",
            "docs/ci-kvm-runner.md",
            "Workload",
        ] {
            #expect(body.contains(needle), "CI helper should reference \(needle)")
        }
        #expect(!body.localizedCaseInsensitiveContains("cluster"))
        #expect(!body.localizedCaseInsensitiveContains("quorum"))

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
        #expect(dry.1.contains("DRY_RUN OK"))

        let skipEnv = ["CI_FORCE_NO_KVM": "1"]
        let probed = try run(args: ["probe"], extraEnv: skipEnv)
        #expect(probed.0 == 0, "probe skip exit \(probed.0): \(probed.1)")
        #expect(probed.1.contains("kvm=no"))

        let skipped = try run(args: ["blank"], extraEnv: skipEnv)
        #expect(skipped.0 == 0, "blank skip exit \(skipped.0): \(skipped.1)")
        #expect(skipped.1.contains("SKIP: /dev/kvm is not usable"))

        let required = try run(args: ["probe"], extraEnv: [
            "CI_FORCE_NO_KVM": "1",
            "REQUIRE_KVM": "1",
        ])
        #expect(required.0 != 0, "REQUIRE_KVM probe should fail without kvm: \(required.1)")
        #expect(required.1.contains("docs/ci-kvm-runner.md"))
    }

    @Test func `guest-boot workflow is optional and does not change required CI`() throws {
        let workflow = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/guest-boot.yml"),
            encoding: .utf8,
        )
        for needle in [
            "name: Guest Boot",
            "ubuntu-24.04",
            "/dev/kvm",
            "KVM_RUNNER_ENABLED",
            "self-hosted, linux, kvm",
            "run-guest-boot",
            "cron:",
            "upload-artifact",
            "ci-guest-boot.sh",
            "NEVER a required status check",
            "guest-boot-bdd.sh",
            "sha256sum -c",
        ] {
            #expect(workflow.contains(needle), "guest-boot.yml should mention \(needle)")
        }
        #expect(workflow.contains("da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19"))
        #expect(workflow.contains("47126395429653fa768d370655876ec1b68f6a95c7884f5e4f179700141c9b7f"))
        #expect(workflow.contains("if: vars.KVM_RUNNER_ENABLED == 'true'"))
        #expect(!workflow.localizedCaseInsensitiveContains("cluster"))
        #expect(!workflow.localizedCaseInsensitiveContains("quorum"))

        let ci = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8,
        )
        #expect(ci.contains("name: Lint & Format"))
        #expect(ci.contains("name: Build"))
        #expect(ci.contains("name: Test"))
        #expect(ci.contains("name: Linux Build"))
        #expect(!ci.contains("guest-boot"))
        #expect(!ci.contains("KVM_RUNNER_ENABLED"))
        #expect(!ci.contains("linux-guest-smoke"))

        let docs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/ci-kvm-runner.md"),
            encoding: .utf8,
        )
        for needle in [
            "KVM_RUNNER_ENABLED",
            "self-hosted",
            "linux",
            "kvm",
            "/dev/kvm",
            "run-guest-boot",
            "never a required",
            "Device",
            "Workload",
            "Home",
            "install-swift-linux.sh",
        ] {
            #expect(docs.contains(needle), "ci-kvm-runner.md should mention \(needle)")
        }
        #expect(!docs.localizedCaseInsensitiveContains("cluster"))
        #expect(!docs.localizedCaseInsensitiveContains("quorum"))

        let mise = try String(
            contentsOf: repoRoot.appendingPathComponent("mise.toml"),
            encoding: .utf8,
        )
        let prepushDeps = defaultPrepushDepends(mise)
        #expect(prepushDeps == ["lint", "test", "frontend-test"])
        let prepushTable = try #require(miseTaskTable(mise, name: "prepush"))
        #expect(!prepushTable.contains("guest-smoke"))
        #expect(!prepushTable.contains("host-network-extra-ip"))
    }

    @Test func `host-network extra-IP BDD exists and dry-run succeeds`() throws {
        let feature = repoRoot.appendingPathComponent("features/host-network-extra-ip.feature")
        let bdd = repoRoot.appendingPathComponent("scripts/linux-host-network-bdd.sh")
        let docker = repoRoot.appendingPathComponent("scripts/linux-host-network-docker.sh")
        #expect(FileManager.default.fileExists(atPath: feature.path))
        #expect(FileManager.default.isExecutableFile(atPath: bdd.path))
        #expect(FileManager.default.isExecutableFile(atPath: docker.path))

        let featureBody = try String(contentsOf: feature, encoding: .utf8)
        for needle in [
            "Scenario: add an extra IP then remove it",
            "ip addr del",
            "10.200.55.50/24",
            "address-only",
            "Mac Apply is verified on the Mini by hand",
        ] {
            #expect(featureBody.contains(needle), "feature should mention \(needle)")
        }

        let bddBody = try String(contentsOf: bdd, encoding: .utf8)
        for needle in [
            "features/host-network-extra-ip.feature",
            "/api/system/interfaces",
            "ip addr del",
            "action:\"commit\"",
            "linux-smoke-common.sh",
        ] {
            #expect(bddBody.contains(needle), "bdd should reference \(needle)")
        }

        let dockerBody = try String(contentsOf: docker, encoding: .utf8)
        for needle in [
            "linux-host-network-bdd.sh",
            "NET_ADMIN",
            "swift:6.3.3-noble",
            "SKIP: docker not on PATH",
        ] {
            #expect(dockerBody.contains(needle), "docker wrapper should reference \(needle)")
        }

        let linuxDocs = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/getting-started-linux.md"),
            encoding: .utf8,
        )
        #expect(linuxDocs.contains("mise run host-network-extra-ip"))

        func run(path: URL, extraEnv: [String: String] = [:]) throws -> (Int32, String) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [path.path]
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

        let dryBdd = try run(path: bdd, extraEnv: ["DRY_RUN": "1"])
        #expect(dryBdd.0 == 0, "bdd DRY_RUN exit \(dryBdd.0): \(dryBdd.1)")
        #expect(dryBdd.1.contains("DRY_RUN OK"))

        let dryDocker = try run(path: docker, extraEnv: ["DRY_RUN": "1"])
        #expect(dryDocker.0 == 0, "docker DRY_RUN exit \(dryDocker.0): \(dryDocker.1)")
        #expect(dryDocker.1.contains("DRY_RUN OK"))

        let skipped = try run(path: bdd, extraEnv: ["BDD_FORCE_SKIP": "1"])
        #expect(skipped.0 == 0, "skip exit \(skipped.0): \(skipped.1)")
        #expect(skipped.1.contains("SKIP:"))
    }

    @Test func `starlight changelog and terminology keep Roadmap links`() throws {
        let changelog = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "website/src/content/docs/docs/changelog.md",
            ),
            encoding: .utf8,
        )
        #expect(changelog.contains("/docs/roadmap/"))
        let terms = try String(
            contentsOf: repoRoot.appendingPathComponent(
                "website/src/content/docs/docs/concepts/terminology.md",
            ),
            encoding: .utf8,
        )
        #expect(terms.contains("/docs/roadmap/"))
        let srcChange = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/changelog.md"),
            encoding: .utf8,
        )
        #expect(srcChange.contains("roadmap.md"))
        let srcTerms = try String(
            contentsOf: repoRoot.appendingPathComponent("docs/product-terminology.md"),
            encoding: .utf8,
        )
        #expect(srcTerms.contains("roadmap.md"))
    }
}
