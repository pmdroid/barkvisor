import Foundation
import Testing
import Yams
@testable import BarkVisorCore

struct OnyxImageTests {
    @Test func `catalog ships one image family for both arches`() throws {
        let url = repoRoot().appendingPathComponent("repos/images.json")
        let catalog = try JSONDecoder().decode(RepoCatalog.self, from: Data(contentsOf: url))
        let rows = catalog.images.filter { OnyxImage.slugs.contains($0.slug) }
        #expect(Set(rows.map(\.slug)) == OnyxImage.slugs)
        #expect(Set(rows.map(\.arch)) == ["arm64", "x86_64"])
        #expect(rows.allSatisfy { $0.name == OnyxImage.name })
        #expect(rows.allSatisfy { $0.imageType == "cloud-image" })
        #expect(rows.allSatisfy { ($0.description ?? "").contains("10.0.2.2:11434") })
        let ubuntu = Dictionary(
            uniqueKeysWithValues: catalog.images.filter { $0.slug.hasPrefix("ubuntu-24.04-") }
                .map { ($0.arch, $0) },
        )
        for row in rows {
            let base = try #require(ubuntu[row.arch])
            #expect(row.downloadUrl == base.downloadUrl)
            #expect(row.sha256 == base.sha256)
        }
    }

    @Test func `matches name and slug not generic ubuntu`() {
        #expect(OnyxImage.matches(name: "Onyx", slug: nil))
        #expect(OnyxImage.matches(name: "onyx", slug: nil))
        #expect(!OnyxImage.matches(name: "my onyx lab", slug: nil))
        #expect(OnyxImage.matches(name: "Ubuntu", slug: "onyx-arm64"))
        #expect(!OnyxImage.matches(name: "Onyx", slug: "ubuntu-24.04-arm64"))
        #expect(!OnyxImage.matches(name: "Ubuntu 24.04 LTS", slug: "ubuntu-24.04-arm64"))
        #expect(!OnyxImage.matches(name: nil, slug: nil))
        #expect(!OnyxImage.matches(name: "Coding Agent", slug: nil))
    }

    @Test func `omitted class becomes agent house stays house`() {
        #expect(OnyxImage.defaultWorkloadClass(explicit: nil) == "agent")
        #expect(OnyxImage.defaultWorkloadClass(explicit: "  ") == "agent")
        #expect(OnyxImage.defaultWorkloadClass(explicit: "house") == "house")
        #expect(OnyxImage.defaultWorkloadClass(explicit: "agent") == "agent")
    }

    @Test func `user-data is valid cloud-init and points at cage ollama not jwt`() throws {
        let yaml = OnyxImage.userData()
        try CloudInitService.validateUserData(yaml)
        #expect(yaml.contains(OnyxImage.setupMarker))
        #expect(yaml.contains("docker-compose.onyx-lite.yml"))
        #expect(yaml.contains("docker compose -f docker-compose.yml -f docker-compose.onyx-lite.yml"))
        #expect(yaml.contains(OnyxImage.releaseTag))
        #expect(yaml.contains(OnyxImage.gitURL))
        #expect(yaml.contains(OnyxImage.ollamaAPIBase))
        #expect(yaml.contains("10.0.2.2:11434"))
        #expect(!yaml.contains("10.0.2.2:11434/v1"))
        #expect(!yaml.contains(":7777"))
        #expect(!yaml.contains("Authorization: Bearer"))
        #expect(!yaml.contains("OPENAI_API_KEY="))
        #expect(yaml.contains(AgentNetworkCage.allowHostOllamaYAML))
        #expect(AgentNetworkCage.allowHostOllama(userData: yaml))
        #expect(OnyxImage.isManagedUserData(yaml))
        #expect(OnyxImage.wantsWebUI(userData: yaml))
        guard let node = try Yams.compose(yaml: "#cloud-config\n" + yaml) else {
            Issue.record("Yams dropped Onyx user-data")
            return
        }
        let persisted = try Yams.serialize(node: node)
        #expect(persisted.contains(AgentNetworkCage.allowHostOllamaKey))
        #expect(AgentNetworkCage.allowHostOllama(userData: persisted))
    }

    @Test func `create defaults inject agent class ollama user-data and sizes`() throws {
        let params = CreateVMParams(
            name: "onyx",
            vmType: "linux-arm64",
            cpuCount: 1,
            memoryMB: 1_024,
            diskSizeGB: 10,
            cloudImageId: "img-1",
        )
        let applied = try OnyxImage.applyingCreateDefaults(
            params: params,
            imageName: "Onyx",
        )
        #expect(applied.workloadClass == "agent")
        #expect(applied.cpuCount == 2)
        #expect(applied.memoryMB == 2_048)
        #expect(applied.diskSizeGB == 20)
        #expect(applied.cloudInit?.userData?.contains("docker-compose.onyx-lite.yml") == true)
        #expect(applied.cloudInit?.userData?.contains("10.0.2.2:11434") == true)
        #expect(applied.cloudInit?.userData?.contains("Authorization: Bearer") != true)
        #expect(applied.cloudInit?.userData?.contains("OPENAI_API_KEY=") != true)

        let ubuntu = try OnyxImage.applyingCreateDefaults(
            params: params,
            imageName: "Ubuntu 24.04 LTS",
        )
        #expect(ubuntu.workloadClass == nil)
        #expect(ubuntu.cloudInit == nil)
        #expect(ubuntu.memoryMB == 1_024)

        let bySlug = try OnyxImage.applyingCreateDefaults(
            params: params,
            imageName: "Ubuntu 24.04 LTS",
            imageSlug: "onyx-arm64",
        )
        #expect(bySlug.workloadClass == "agent")

        let slugWins = try OnyxImage.applyingCreateDefaults(
            params: params,
            imageName: "Onyx",
            imageSlug: "ubuntu-24.04-arm64",
        )
        #expect(slugWins.workloadClass == nil)

        let house = CreateVMParams(
            name: "onyx",
            vmType: "linux-arm64",
            cpuCount: 2,
            memoryMB: 2_048,
            diskSizeGB: 20,
            cloudImageId: "img-1",
            cloudInit: CloudInitConfig(sshAuthorizedKeys: nil, userData: "packages:\n  - vim\n"),
            workloadClass: "house",
        )
        let kept = try OnyxImage.applyingCreateDefaults(
            params: house,
            imageName: "Onyx",
        )
        #expect(kept.workloadClass == "house")
        #expect(kept.cloudInit?.userData?.contains("vim") == true)
        #expect(kept.cloudInit?.userData?.contains("barkvisor-onyx-setup") != true)
    }

    @Test func `console and frontend user-data keep compose overlay and cage url`() throws {
        let root = repoRoot()
        let console = try String(
            contentsOf: root.appendingPathComponent(
                "Apps/BarkVisorConsole/Sources/Models/OnyxImage.swift",
            ),
            encoding: .utf8,
        )
        let frontend = try String(
            contentsOf: root.appendingPathComponent("frontend/src/utils/onyxImage.ts"),
            encoding: .utf8,
        )
        for source in [console, frontend] {
            #expect(source.contains("docker-compose.onyx-lite.yml"))
            #expect(source.contains("http://10.0.2.2:11434"))
            #expect(source.contains("barkvisor_allow_host_ollama: true"))
            #expect(!source.contains("barkvisor_abc"))
            #expect(!source.contains(":7777"))
        }
    }
}

private func repoRoot() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
    }
    Issue.record("could not find Package.swift from \(#filePath)")
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}
