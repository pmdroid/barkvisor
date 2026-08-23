import Foundation
import Testing
@testable import BarkVisorCore

struct CodingAgentImageTests {
    @Test func `catalog ships one image family for both arches`() throws {
        let url = repoRoot().appendingPathComponent("repos/images.json")
        let catalog = try JSONDecoder().decode(RepoCatalog.self, from: Data(contentsOf: url))
        let rows = catalog.images.filter { CodingAgentImage.slugs.contains($0.slug) }
        #expect(Set(rows.map(\.slug)) == CodingAgentImage.slugs)
        #expect(Set(rows.map(\.arch)) == ["arm64", "x86_64"])
        #expect(rows.allSatisfy { $0.name == CodingAgentImage.name })
        #expect(rows.allSatisfy { $0.imageType == "cloud-image" })
        #expect(rows.allSatisfy { ($0.description ?? "").contains("OPENAI_BASE_URL") })
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
        #expect(CodingAgentImage.matches(name: "Coding Agent", slug: nil))
        #expect(CodingAgentImage.matches(name: "coding agent", slug: nil))
        #expect(!CodingAgentImage.matches(name: "my coding agent lab", slug: nil))
        #expect(CodingAgentImage.matches(name: "Ubuntu", slug: "coding-agent-arm64"))
        #expect(!CodingAgentImage.matches(name: "Coding Agent", slug: "ubuntu-24.04-arm64"))
        #expect(!CodingAgentImage.matches(name: "Ubuntu 24.04 LTS", slug: "ubuntu-24.04-arm64"))
        #expect(!CodingAgentImage.matches(name: nil, slug: nil))
    }

    @Test func `omitted class becomes agent house stays house`() {
        #expect(CodingAgentImage.defaultWorkloadClass(explicit: nil) == "agent")
        #expect(CodingAgentImage.defaultWorkloadClass(explicit: "  ") == "agent")
        #expect(CodingAgentImage.defaultWorkloadClass(explicit: "house") == "house")
        #expect(CodingAgentImage.defaultWorkloadClass(explicit: "agent") == "agent")
    }

    @Test func `openai url defaults to device ollama and rejects junk`() throws {
        #expect(try CodingAgentImage.normalizeOpenAIBaseURL(nil) == CodingAgentImage.deviceOllamaBaseURL)
        #expect(try CodingAgentImage.normalizeOpenAIBaseURL("https://api.example/v1") == "https://api.example/v1")
        #expect(throws: BarkVisorError.self) {
            try CodingAgentImage.normalizeOpenAIBaseURL("ftp://x")
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentImage.normalizeOpenAIBaseURL("https://evil\n.com")
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentImage.normalizeOpenAIBaseURL("https://x$(reboot).example/v1")
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentImage.normalizeOpenAIBaseURL("https://x`id`.example/v1")
        }
        #expect(throws: BarkVisorError.self) {
            try CodingAgentImage.normalizeOpenAIBaseURL("https://x$HOME.example/v1")
        }
        #expect(CodingAgentImage.isShellSafeOpenAIBaseURL(CodingAgentImage.homeOllamaGrantURL))
        #expect(CodingAgentImage.homeOllamaGrantURL == CodingAgentImage.deviceOllamaBaseURL)
        #expect(CodingAgentImage.deviceOllamaBaseURL.contains("10.0.2.2:11434"))
    }

    @Test func `default user-data is valid cloud-init and names the tools`() throws {
        let yaml = CodingAgentImage.userData(openaiBaseURL: CodingAgentImage.deviceOllamaBaseURL)
        try CloudInitService.validateUserData(yaml)
        #expect(yaml.contains("git"))
        #expect(yaml.contains("ttyd"))
        #expect(yaml.contains("ttyd.service"))
        #expect(yaml.contains("systemctl enable --now ttyd"))
        #expect(yaml.contains("sha256sum -c"))
        #expect(yaml.contains(CodingAgentImage.ttydSha256Aarch64))
        #expect(yaml.contains(CodingAgentImage.ttydSha256Amd64))
        #expect(yaml.contains("/usr/local/bin"))
        #expect(yaml.contains("su -s /bin/bash"))
        #expect(yaml.contains("claude.ai/install.sh"))
        #expect(yaml.contains("opencode.ai/install"))
        #expect(yaml.contains("OPENAI_BASE_URL='http://10.0.2.2:11434/v1'"))
        #expect(yaml.contains("/etc/default/barkvisor-openai"))
        #expect(yaml.contains("EnvironmentFile=-/etc/default/barkvisor-openai"))
        #expect(!yaml.contains("OPENAI_BASE_URL=\"http://"))
        let byo = CodingAgentImage.userData(openaiBaseURL: "https://api.openai.com/v1")
        try CloudInitService.validateUserData(byo)
        #expect(byo.contains("https://api.openai.com/v1"))
    }

    @Test func `create defaults inject agent class and ollama user-data`() throws {
        let params = CreateVMParams(
            name: "coder",
            vmType: "linux-arm64",
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 10,
            cloudImageId: "img-1",
        )
        let applied = try CodingAgentImage.applyingCreateDefaults(
            params: params,
            imageName: "Coding Agent",
        )
        #expect(applied.workloadClass == "agent")
        #expect(applied.cloudInit?.userData?.contains("OPENAI_BASE_URL") == true)
        #expect(applied.cloudInit?.userData?.contains("git") == true)

        let ubuntu = try CodingAgentImage.applyingCreateDefaults(
            params: params,
            imageName: "Ubuntu 24.04 LTS",
        )
        #expect(ubuntu.workloadClass == nil)
        #expect(ubuntu.cloudInit == nil)

        let substring = try CodingAgentImage.applyingCreateDefaults(
            params: params,
            imageName: "my coding agent lab",
        )
        #expect(substring.workloadClass == nil)
        #expect(substring.cloudInit == nil)

        let bySlug = try CodingAgentImage.applyingCreateDefaults(
            params: params,
            imageName: "Ubuntu 24.04 LTS",
            imageSlug: "coding-agent-arm64",
        )
        #expect(bySlug.workloadClass == "agent")

        let slugWins = try CodingAgentImage.applyingCreateDefaults(
            params: params,
            imageName: "Coding Agent",
            imageSlug: "ubuntu-24.04-arm64",
        )
        #expect(slugWins.workloadClass == nil)
        #expect(slugWins.cloudInit == nil)

        let house = CreateVMParams(
            name: "coder",
            vmType: "linux-arm64",
            cpuCount: 2,
            memoryMB: 1_024,
            diskSizeGB: 10,
            cloudImageId: "img-1",
            cloudInit: CloudInitConfig(sshAuthorizedKeys: nil, userData: "packages:\n  - vim\n"),
            workloadClass: "house",
        )
        let kept = try CodingAgentImage.applyingCreateDefaults(
            params: house,
            imageName: "Coding Agent",
        )
        #expect(kept.workloadClass == "house")
        #expect(kept.cloudInit?.userData?.contains("vim") == true)
        #expect(kept.cloudInit?.userData?.contains("ttyd") != true)
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
