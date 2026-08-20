import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

struct GuestTypeResolverTests {
    private struct Case: Decodable {
        let guestType: String?
        let osFamily: String?
        let arch: String?
        let id: String
        let defaultTPMEnabled: Bool
    }

    private static func loadCases() throws -> [Case] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/guest-type-resolver.cases.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Case].self, from: data)
    }

    @Test func `wizard API and spec keys agree`() throws {
        for row in try Self.loadCases() {
            let shared = try GuestProfiles.resolve(
                guestType: row.guestType,
                osFamily: row.osFamily,
                arch: row.arch,
            )
            let api = try VMController.resolveFlatGuestType(
                vmType: row.guestType,
                osFamily: row.osFamily,
                arch: row.arch,
            )
            let spec = WorkloadSpec(
                metadata: WorkloadMetadata(name: "n"),
                spec: WorkloadSpecBody(
                    resources: WorkloadResources(cpu: 1, memoryMb: 512),
                    arch: row.arch,
                    guestType: row.guestType,
                    osFamily: row.osFamily,
                ),
            )
            let specKey = try WorkloadSpecProjector.resolveGuestType(spec)
            #expect(shared == row.id)
            #expect(api == row.id)
            #expect(specKey == row.id)
            #expect(try GuestProfiles.require(row.id).defaultTPMEnabled == row.defaultTPMEnabled)
        }
    }

    @Test func `omitted x86 linux is linux-amd64 not linux-x86_64`() throws {
        #expect(
            try GuestProfiles.resolve(osFamily: "linux", arch: "x86_64") == "linux-amd64",
        )
        #expect(
            try GuestProfiles.resolve(guestType: "linux-x86_64") == "linux-x86_64",
        )
    }

    @Test func `windows-amd64 stays in the table`() throws {
        let profile = try GuestProfiles.require("windows-amd64")
        #expect(profile.osFamily == "windows")
        #expect(profile.arch == "x86_64")
        #expect(profile.defaultTPMEnabled)
        #expect(GuestProfiles.supportedIDs.contains("linux-x86_64"))
    }

    @Test func `explicit guestType rejects arch mismatch`() {
        #expect(throws: BarkVisorError.self) {
            try GuestProfiles.resolve(guestType: "linux-arm64", arch: "x86_64")
        }
        #expect(throws: BarkVisorError.self) {
            try WorkloadSpecProjector.resolveGuestType(
                WorkloadSpec(
                    metadata: WorkloadMetadata(name: "n"),
                    spec: WorkloadSpecBody(
                        resources: WorkloadResources(cpu: 1, memoryMb: 512),
                        arch: "x86_64",
                        guestType: "linux-arm64",
                    ),
                ),
            )
        }
    }

    @Test func `omitted type uses host arch`() throws {
        let host = PlatformCapabilities.hostArch
        #expect(
            try GuestProfiles.resolve(osFamily: "linux")
                == GuestProfiles.defaultLinuxID(forImageArch: host),
        )
        #expect(
            try VMController.resolveFlatGuestType(vmType: nil, osFamily: nil)
                == GuestProfiles.defaultLinuxID(forImageArch: host),
        )
        let spec = WorkloadSpec(
            metadata: WorkloadMetadata(name: "n"),
            spec: WorkloadSpecBody(resources: WorkloadResources(cpu: 1, memoryMb: 512)),
        )
        #expect(
            try WorkloadSpecProjector.resolveGuestType(spec)
                == GuestProfiles.defaultLinuxID(forImageArch: host),
        )
    }
}
