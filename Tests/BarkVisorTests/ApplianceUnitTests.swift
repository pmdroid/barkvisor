import Foundation
import Testing
@testable import BarkVisorCore

struct ApplianceUnitTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `package enables daemon and server and rejects A downgrade before chown`() throws {
        for relative in [
            "packaging/linux/debian/postinst",
            "packaging/linux/rpm/barkvisor.spec.in",
            "packaging/linux/arch/barkvisor.install",
            "scripts/install-linux.sh",
            "scripts/build-linux-packages.sh",
            "packaging/homebrew/postinstall.sh",
            "scripts/pkg-service-handoff.sh",
        ] {
            let script = try read(relative)
            #expect(script.contains("schema-version"), "\(relative)")
            #expect(!script.contains("systemctl enable barkvisor.service"), "\(relative)")
            if !relative.contains("homebrew/postinstall.sh") {
                #expect(script.contains("barkvisor-daemon"), "\(relative)")
                #expect(script.contains("barkvisor-server"), "\(relative)")
            }
            let schema = try #require(script.range(of: "schema-version"))
            if let chown = script.range(of: "chown") ?? script.range(of: "chgrp") ?? script.range(of: "install -d -o") {
                #expect(schema.lowerBound < chown.lowerBound, "\(relative)")
            }
        }
        let formula = try read("packaging/homebrew/barkvisor.rb")
        #expect(formula.contains("homebrew.mxcl.barkvisor-daemon"))
        #expect(formula.contains("homebrew.mxcl.barkvisor-server"))
        let postinst = try read("packaging/linux/debian/postinst")
        #expect(postinst.contains("systemctl enable barkvisor-daemon.service"))
        #expect(postinst.contains("systemctl enable barkvisor-server.service"))
        #expect(postinst.contains("systemctl disable barkvisor.service"))
        let stopped = try #require(postinst.range(of: "systemctl disable --now barkvisor.service"))
        let enabled = try #require(postinst.range(of: "systemctl enable barkvisor-daemon.service"))
        #expect(stopped.lowerBound < enabled.lowerBound)
        #expect(postinst.contains("systemctl start barkvisor-server.service"))
        let daemon = try read("packaging/linux/barkvisor-daemon.service")
        let server = try read("packaging/linux/barkvisor-server.service")
        #expect(daemon.contains("User=root"))
        #expect(daemon.contains("RuntimeDirectoryMode=0770"))
        #expect(server.contains("User=barkvisor"))
        #expect(server.contains("InaccessiblePaths=-/run/docker.sock"))
        #expect(!ApplianceUnits.allowsDowngrade(onDiskSchema: 2))
        #expect(ApplianceUnits.allowsDowngrade(onDiskSchema: 1))
        #expect(ApplianceUnits.allowsDowngrade(onDiskSchema: nil))
        #expect(ApplianceUnits.doctorLine.contains("barkvisor-daemon"))
        #expect(ApplianceUnits.doctorLine.contains("barkvisor-server"))
        let prerm = try read("packaging/linux/debian/prerm")
        let upgrade = try #require(prerm.range(of: "upgrade)"))
        let remove = try #require(prerm.range(of: "remove|deconfigure"))
        let upgradeBody = String(prerm[upgrade.upperBound ..< remove.lowerBound])
        #expect(!upgradeBody.contains("stop barkvisor-daemon.service"))
    }
}
