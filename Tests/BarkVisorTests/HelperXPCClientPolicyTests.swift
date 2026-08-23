#if os(macOS)
    import BarkVisorHelperProtocol
    import Foundation
    import Testing

    struct HelperXPCClientPolicyTests {
        private let prefixes = ["/opt/homebrew", "/usr/local"]

        @Test func `pkg team ID client is accepted without a homebrew path`() {
            #expect(
                helperAllowsXPCClient(
                    identifier: kHelperClientIdentifier,
                    teamID: kHelperTeamID,
                    isAdHoc: false,
                    executablePath: "/usr/local/bin/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
        }

        @Test func `homebrew ad-hoc client under prefix is accepted`() {
            #expect(
                helperAllowsXPCClient(
                    identifier: kHelperClientIdentifier,
                    teamID: nil,
                    isAdHoc: true,
                    executablePath: "/opt/homebrew/opt/barkvisor/bin/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
        }

        @Test func `ad-hoc client outside homebrew prefix is rejected`() {
            #expect(
                !helperAllowsXPCClient(
                    identifier: kHelperClientIdentifier,
                    teamID: nil,
                    isAdHoc: true,
                    executablePath: "/tmp/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
        }

        @Test func `unsigned or wrong identifier is rejected`() {
            #expect(
                !helperAllowsXPCClient(
                    identifier: nil,
                    teamID: nil,
                    isAdHoc: true,
                    executablePath: "/opt/homebrew/opt/barkvisor/bin/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
            #expect(
                !helperAllowsXPCClient(
                    identifier: "com.example.notbarkvisor",
                    teamID: nil,
                    isAdHoc: true,
                    executablePath: "/opt/homebrew/opt/barkvisor/bin/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
        }

        @Test func `foreign team ID is rejected even under homebrew prefix`() {
            #expect(
                !helperAllowsXPCClient(
                    identifier: kHelperClientIdentifier,
                    teamID: "ABCD123456",
                    isAdHoc: false,
                    executablePath: "/opt/homebrew/opt/barkvisor/bin/barkvisor",
                    homebrewPrefixes: prefixes,
                ),
            )
        }

        @Test func `random ad-hoc binary name under prefix is rejected`() {
            #expect(
                !helperClientPathIsHomebrewBarkVisor(
                    "/opt/homebrew/bin/not-barkvisor",
                    prefixes: prefixes,
                ),
            )
        }

        @Test func `missing team ID is treated as ad-hoc`() {
            #expect(helperSigningIsAdHoc(teamID: nil))
            #expect(helperSigningIsAdHoc(teamID: ""))
            #expect(!helperSigningIsAdHoc(teamID: kHelperTeamID))
            #expect(helperSigningIsAdHoc(teamID: kHelperTeamID, flags: 0x0000_0002))
        }

        @Test func `helper release gate keeps team ID and homebrew ad-hoc path`() throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            let main = try String(
                contentsOf: root.appendingPathComponent("Sources/BarkVisorHelper/main.swift"),
                encoding: .utf8,
            )
            #expect(main.contains("helperCodeRequirement"))
            #expect(main.contains("kHelperTeamID"))
            #expect(main.contains("helperAllowsXPCClient"))
            #expect(main.contains("helperClientIdentifierRequirement"))
            #expect(main.contains("#if DEBUG"))
        }
    }
#endif
