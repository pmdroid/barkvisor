import Foundation
import Testing

/// Structural checks for the Linux product-proof scripts (guest smoke + SPA serve).
struct LinuxGuestScriptsTests {
    private var repoRoot: URL {
        // Tests/BarkVisorTests/ThisFile.swift → repo root is two levels up.
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
        ] {
            #expect(body.contains(needle), "smoke script should reference \(needle)")
        }
    }

    @Test func `linux frontend serve script exists and is executable`() throws {
        let path = repoRoot.appendingPathComponent("scripts/linux-frontend-serve.sh").path
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(FileManager.default.isExecutableFile(atPath: path))

        let body = try String(contentsOfFile: path, encoding: .utf8)
        #expect(body.contains("BARKVISOR_FRONTEND_DIR"))
        #expect(body.contains("bun"))
    }
}
