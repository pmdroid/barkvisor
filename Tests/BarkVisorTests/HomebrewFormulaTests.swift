import Foundation
import Testing

/// PAS-291: Homebrew formula + root brew services LaunchDaemon (no helper yet).
struct HomebrewFormulaTests {
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

    private func serviceBlock(_ formula: String) throws -> String {
        guard let start = formula.range(of: "service do") else {
            throw HomebrewFormulaTestError.missingServiceBlock
        }
        let rest = formula[start.lowerBound...]
        guard let end = rest.range(of: "\n  end\n") else {
            throw HomebrewFormulaTestError.missingServiceBlock
        }
        return String(rest[..<end.upperBound])
    }

    @Test func `formula depends on qemu swtpm socket_vmnet cdrtools`() throws {
        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(formula.contains("depends_on :macos"))
        #expect(formula.contains("depends_on arch: :arm64"))
        for dep in ["qemu", "swtpm", "socket_vmnet", "cdrtools"] {
            #expect(formula.contains("depends_on \"\(dep)\""), "missing depends_on \(dep)")
        }
    }

    @Test func `brew services is a root LaunchDaemon without regenerating the plist`() throws {
        let formula = try read("packaging/homebrew/barkvisor.rb")
        let service = try serviceBlock(formula)
        #expect(service.contains("require_root true"))
        #expect(service.contains("name macos: \"homebrew.mxcl.barkvisor\""))
        #expect(!service.contains("\n    run "), "DSL run would drop AbandonProcessGroup")
        #expect(formula.contains("AbandonProcessGroup"))
        #expect(formula.contains("homebrew.mxcl.barkvisor.plist"))
    }

    @Test func `shipped plist keeps Workloads alive across daemon restart`() throws {
        let plist = try read("packaging/homebrew/homebrew.mxcl.barkvisor.plist")
        #expect(plist.contains("<key>AbandonProcessGroup</key>"))
        #expect(plist.contains("<key>UserName</key>"))
        #expect(plist.contains("<string>_barkvisor</string>"))
        #expect(plist.contains("<key>GroupName</key>\n    <string>_barkvisor</string>"))
        #expect(plist.contains("<key>WorkingDirectory</key>\n    <string>/var/lib/barkvisor</string>"))
        #expect(plist.contains("<key>BARKVISOR_DATA_DIR</key>"))
        #expect(plist.contains("<key>BARKVISOR_SOCKET_DIR</key>"))
        #expect(plist.contains("<string>/var/run/barkvisor</string>"))
        #expect(plist.contains("<key>PATH</key>"))
        #expect(plist.contains("@HOMEBREW_PREFIX@/bin"))
        #expect(plist.contains("@PROGRAM@"))
        #expect(!plist.contains("barkvisor.helper"))
        #expect(!plist.contains("PrivilegedHelperTools"))
    }

    @Test func `postinstall creates the system user and data dirs`() throws {
        let script = try read("packaging/homebrew/postinstall.sh")
        #expect(script.contains("_barkvisor"))
        #expect(script.contains("dscl"))
        #expect(script.contains("/var/lib/barkvisor"))
        #expect(script.contains("/var/run/barkvisor"))
        #expect(script.contains("/var/log/barkvisor"))
        #expect(!script.contains("dev.barkvisor.helper"))
        #expect(!script.contains("PrivilegedHelperTools"))
        #expect(!script.contains("launchctl bootstrap"))

        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(formula.contains("def post_install"))
        #expect(formula.contains("pkgshare/\"postinstall\""))
        #expect(formula.contains("_barkvisor"))
        #expect(formula.contains("/var/lib/barkvisor"))
    }

    @Test func `formula installs templates.json into shareDir`() throws {
        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(formula.contains("(share/\"barkvisor\").install \"repos/templates.json\""))
        #expect(formula.contains("assert_path_exists share/\"barkvisor/templates.json\""))
        let plist = try read("packaging/homebrew/homebrew.mxcl.barkvisor.plist")
        #expect(plist.contains("<key>WorkingDirectory</key>"))
        #expect(plist.contains("<string>/var/lib/barkvisor</string>"))
    }

    @Test func `formula does not ship a helper LaunchDaemon`() throws {
        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(!formula.contains("dev.barkvisor.helper"))
        #expect(!formula.contains("PrivilegedHelperTools"))
        #expect(!formula.contains("MachServices"))
        #expect(formula.contains("PAS-292"))
    }

    private enum HomebrewFormulaTestError: Error {
        case missingServiceBlock
    }
}
