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
    }

    struct HelperHandlerSourcePolicyTests {
        @Test func `helper does not chmod bridged sockets world writable`() throws {
            let utilities = try String(contentsOf: Self.helperUtilitiesURL(), encoding: .utf8)
            #expect(!utilities.contains("0o777"))
            #expect(utilities.contains("kHelperBridgeSocketMode"))
            #expect(utilities.contains("chown"))
            #expect(utilities.contains("hasTrustedSocketVmnetSignature"))
            #expect(utilities.contains("helperCodeRequirement"))
            #expect(!utilities.contains("SecStaticCodeCheckValidity(code, [], nil)"))
            #expect(utilities.contains("0o600"))
        }

        @Test func `helper has no in-app pkg installer`() throws {
            let handler = try String(contentsOf: Self.helperHandlerURL(), encoding: .utf8)
            #expect(!handler.contains("installUpdate"))
            #expect(!handler.contains("stageUpdatePackage"))
            #expect(!handler.contains("/usr/sbin/installer"))
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
