#if os(macOS)
    import BarkVisorHelperProtocol
    import Foundation
    import Testing

    struct HelperSecurityTests {
        @Test func `bridge socket mode is group accessible not world writable`() {
            #expect(kHelperBridgeSocketMode == 0o660)
            #expect(kHelperBridgeSocketMode & 0o007 == 0)
            #expect(kHelperServiceUser == "_barkvisor")
        }

        @Test func `socket vmnet requirement includes team ID and identifier`() {
            let requirement = helperCodeRequirement(
                identifier: kHelperSocketVmnetIdentifier,
                teamID: kHelperTeamID,
            )
            #expect(requirement.contains("identifier \"socket_vmnet\""))
            #expect(requirement.contains("certificate leaf[subject.OU] = \"\(kHelperTeamID)\""))
            #expect(requirement.contains("anchor apple generic"))
        }

        @Test func `expected version rejects empty and path characters`() {
            #expect(!helperIsSafeExpectedVersion(""))
            #expect(!helperIsSafeExpectedVersion(" "))
            #expect(!helperIsSafeExpectedVersion("../1.0.0"))
            #expect(!helperIsSafeExpectedVersion("1.0.0/evil"))
            #expect(!helperIsSafeExpectedVersion("1.0.0;rm"))
            #expect(helperIsSafeExpectedVersion("1.0.0"))
            #expect(helperIsSafeExpectedVersion("v1.2.3-beta.1"))
        }

        @Test func `normalized versions compare without v prefix`() {
            #expect(helperNormalizedVersion("v1.2.3") == "1.2.3")
            #expect(helperVersionsMatch(expected: "v1.2.3", package: "1.2.3"))
            #expect(helperVersionsMatch(expected: "1.2.3", package: "v1.2.3"))
            #expect(!helperVersionsMatch(expected: "1.2.3", package: "1.2.4"))
            #expect(!helperVersionsMatch(expected: "", package: "1.2.3"))
        }

        @Test func `pkgutil team ID prefers Developer ID Installer line`() {
            let output = """
            Package "BarkVisor-1.2.3.pkg":
               Status: signed by a developer certificate issued by Apple for distribution
               Certificate Chain:
                1. Developer ID Installer: Pascal (W363QN58YY)
                2. Developer ID Certification Authority (ABCDEF1234)
            """
            #expect(helperTeamIDFromPkgutilOutput(output) == "W363QN58YY")
        }

        @Test func `pkgutil team ID missing`() {
            #expect(helperTeamIDFromPkgutilOutput("unsigned package") == nil)
        }

        @Test func `parse version from distribution xml prefers barkvisor pkg-ref`() {
            let xml = """
            <?xml version="1.0" encoding="UTF-8"?>
            <installer-gui-script minSpecVersion="2">
                <title>BarkVisor 1.2.3</title>
                <pkg-ref id="other.pkg" version="9.9.9"/>
                <pkg-ref id="dev.barkvisor" version="1.2.3" onConclusion="none">BarkVisor-component.pkg</pkg-ref>
            </installer-gui-script>
            """
            #expect(helperParsePackageVersion(fromXML: xml) == "1.2.3")
        }

        @Test func `parse version from package info`() {
            let xml = """
            <?xml version="1.0"?>
            <pkg-info identifier="dev.barkvisor" version="2.0.0" install-location="/"/>
            """
            #expect(helperParsePackageVersion(fromXML: xml) == "2.0.0")
        }

        @Test func `parse version ignores minSpecVersion`() {
            let xml = """
            <?xml version="1.0"?>
            <installer-gui-script minSpecVersion="2">
                <pkg-ref id="dev.barkvisor" version="3.1.0"/>
            </installer-gui-script>
            """
            #expect(helperParsePackageVersion(fromXML: xml) == "3.1.0")
        }

        @Test func `parse version from expanded product archive`() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("pas-281-expand-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let distribution = """
            <?xml version="1.0"?>
            <installer-gui-script minSpecVersion="2">
                <pkg-ref id="dev.barkvisor" version="4.5.6"/>
            </installer-gui-script>
            """
            try distribution.write(
                to: root.appendingPathComponent("Distribution"),
                atomically: true,
                encoding: .utf8,
            )
            #expect(helperParsePackageVersion(fromExpandedRoot: root.path) == "4.5.6")
        }

        @Test func `update staging directory is outside the service data dir`() {
            #expect(kHelperUpdateStagingDir == "/var/db/barkvisor-helper/updates")
            #expect(!kHelperUpdateStagingDir.hasPrefix("/var/lib/barkvisor/"))
        }
    }

    struct HelperHandlerSourcePolicyTests {
        @Test func `helper does not chmod bridged sockets world writable`() throws {
            let utilities = try String(contentsOf: Self.helperUtilitiesURL(), encoding: .utf8)
            #expect(!utilities.contains("0o777"))
            #expect(utilities.contains("kHelperBridgeSocketMode"))
            #expect(utilities.contains("chown"))
            #expect(utilities.contains("hasTrustedSocketVmnetSignature"))
            #expect(utilities.contains("helperCodeRequirement"))
        }

        @Test func `installUpdate stages pkg and enforces expectedVersion`() throws {
            let handler = try String(contentsOf: Self.helperHandlerURL(), encoding: .utf8)
            #expect(handler.contains("stageUpdatePackage"))
            #expect(handler.contains("helperVersionsMatch"))
            #expect(handler.contains("helperIsSafeExpectedVersion"))
            #expect(handler.contains("stagedPath"))
        }

        private static func helperUtilitiesURL() -> URL {
            packageRoot().appendingPathComponent("Sources/BarkVisorHelper/HelperHandler+Utilities.swift")
        }

        private static func helperHandlerURL() -> URL {
            packageRoot().appendingPathComponent("Sources/BarkVisorHelper/HelperHandler.swift")
        }

        private static func packageRoot() -> URL {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }
    }
#endif
