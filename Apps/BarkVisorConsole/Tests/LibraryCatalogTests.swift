import Foundation
import Testing
@testable import BarkVisorConsole

struct LibraryCatalogTests {
    private let decoder = JSONDecoder()

    @Test func `empty library copy tells you to download here`() {
        #expect(Copy.emptyLibrary == "Download an image from the catalog below.")
        #expect(LibraryCatalog.emptyLibraryCopy == Copy.emptyLibrary)
        #expect(PhoneTab.library.rawValue == "library")
    }

    @Test func `IOS library prefers this device even when A member is selected`() {
        let selfDevice = snapshot(hostId: "self", role: "self", title: "Studio")
        let member = snapshot(hostId: "peer", role: "member", title: "Living Room")
        let ios = LibraryCatalog.targetDevice(
            devices: [selfDevice, member],
            selectedID: member.hostId,
            preferSelf: true,
        )
        let mac = LibraryCatalog.targetDevice(
            devices: [selfDevice, member],
            selectedID: member.hostId,
            preferSelf: false,
        )
        #expect(ios?.hostId == "self")
        #expect(mac?.hostId == "peer")
    }

    @Test func `library target falls back to self then first`() {
        let selfDevice = snapshot(hostId: "self", role: "self", title: "Studio")
        let member = snapshot(hostId: "peer", role: "member", title: "Living Room")
        #expect(
            LibraryCatalog.targetDevice(devices: [selfDevice, member], selectedID: "missing", preferSelf: false)?
                .hostId == "self",
        )
        #expect(
            LibraryCatalog.targetDevice(devices: [member], selectedID: nil, preferSelf: true)?.hostId == "peer",
        )
    }

    @Test func `catalog download paths stay on the picked device`() throws {
        let client = try APIClient(baseURL: DeviceURL.normalize("http://192.168.30.1:7777"), token: "t")
        let selfDevice = snapshot(hostId: "self", role: "self")
        let member = snapshot(hostId: "peer", role: "member")
        #expect(client.scoped("/repositories", on: selfDevice) == "/api/repositories")
        #expect(
            client.scoped("/repositories/images/img-1/download", on: selfDevice)
                == "/api/repositories/images/img-1/download",
        )
        #expect(
            client.scoped("/repositories/images/img-1/download", on: member)
                == "/api/home/devices/peer/v1/repositories/images/img-1/download",
        )
        #expect(
            client.scoped("/repositories/repo-1/images", on: member)
                == "/api/home/devices/peer/v1/repositories/repo-1/images",
        )
    }

    @Test func `repositories and catalog images decode without host arch`() throws {
        let reposJSON = """
        [
          {
            "id": "repo-images",
            "name": "BarkVisor images",
            "url": "https://example.test/images.json",
            "isBuiltIn": true,
            "repoType": "images",
            "lastSyncedAt": "2026-08-01T00:00:00Z",
            "lastError": null,
            "syncStatus": "idle",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-08-01T00:00:00Z"
          },
          {
            "id": "repo-templates",
            "name": "Templates",
            "url": "https://example.test/templates.json",
            "isBuiltIn": true,
            "repoType": "templates",
            "lastSyncedAt": null,
            "lastError": null,
            "syncStatus": "idle",
            "createdAt": "2026-01-01T00:00:00Z",
            "updatedAt": "2026-01-01T00:00:00Z"
          }
        ]
        """.data(using: .utf8)!
        let catalogJSON = """
        [
          {
            "id": "cat-arm",
            "repositoryId": "repo-images",
            "slug": "ubuntu-24.04",
            "name": "Ubuntu 24.04 ARM",
            "description": "Cloud image",
            "imageType": "cloud-image",
            "arch": "arm64",
            "version": "20260801",
            "downloadUrl": "https://example.test/ubuntu-arm64.img",
            "sizeBytes": 1048576
          },
          {
            "id": "cat-x86",
            "repositoryId": "repo-images",
            "slug": "ubuntu-24.04",
            "name": "Ubuntu 24.04 x86",
            "description": null,
            "imageType": "cloud-image",
            "arch": "x86_64",
            "version": "20260801",
            "downloadUrl": "https://example.test/ubuntu-x86_64.img",
            "sizeBytes": 2097152
          }
        ]
        """.data(using: .utf8)!

        let repos = try decoder.decode([ImageRepository].self, from: reposJSON)
        let catalog = try decoder.decode([CatalogImage].self, from: catalogJSON)
        #expect(LibraryCatalog.imageRepositories(repos).map(\.id) == ["repo-images"])
        #expect(catalog.map(\.arch) == ["arm64", "x86_64"])
        #expect(catalog[0].detailLine.contains("arm64"))
        #expect(catalog[1].detailLine.contains("x86_64"))

        let groups = LibraryCatalog.groups(repos: repos, imagesByRepo: ["repo-images": catalog])
        #expect(groups.count == 1)
        #expect(groups[0].images.map(\.name) == ["Ubuntu 24.04 ARM", "Ubuntu 24.04 x86"])
        #expect(LibraryCatalog.groups(repos: repos, imagesByRepo: [:]).isEmpty)
    }

    @Test func `coding agent catalog row decodes for both arches`() throws {
        let catalogJSON = """
        [
          {
            "id": "ca-arm",
            "repositoryId": "repo-images",
            "slug": "coding-agent-arm64",
            "name": "Coding Agent",
            "description": "Linux with git, web terminal, and coding-agent CLIs.",
            "imageType": "cloud-image",
            "arch": "arm64",
            "version": "24.04",
            "downloadUrl": "https://example.test/coding-agent-arm64.img",
            "sizeBytes": 618370560
          },
          {
            "id": "ca-x86",
            "repositoryId": "repo-images",
            "slug": "coding-agent-x86_64",
            "name": "Coding Agent",
            "description": "Linux with git, web terminal, and coding-agent CLIs.",
            "imageType": "cloud-image",
            "arch": "x86_64",
            "version": "24.04",
            "downloadUrl": "https://example.test/coding-agent-x86_64.img",
            "sizeBytes": 624447488
          }
        ]
        """.data(using: .utf8)!
        let catalog = try decoder.decode([CatalogImage].self, from: catalogJSON)
        #expect(catalog.map(\.slug) == ["coding-agent-arm64", "coding-agent-x86_64"])
        #expect(Set(catalog.map(\.arch)) == ["arm64", "x86_64"])
        #expect(catalog.allSatisfy { $0.name == "Coding Agent" })
        #expect(CodingAgentImage.slugs == Set(catalog.map(\.slug)))
    }

    @Test func `catalog matches library by download url and tracks progress`() {
        let catalog = CatalogImage(
            id: "cat-1",
            repositoryId: "repo-images",
            slug: "haos",
            name: "HAOS",
            description: nil,
            imageType: "ova",
            arch: "arm64",
            version: "12",
            downloadUrl: "https://example.test/haos.qcow2",
            sizeBytes: 100,
        )
        let downloading = libraryImage(status: "downloading", sourceUrl: catalog.downloadUrl)
        let ready = libraryImage(status: "ready", sourceUrl: catalog.downloadUrl)
        let failed = libraryImage(status: "error", sourceUrl: catalog.downloadUrl, error: "checksum")
        let other = libraryImage(status: "ready", sourceUrl: "https://example.test/other.img")

        #expect(LibraryCatalog.libraryImage(for: catalog, in: [other, downloading])?.id == downloading.id)
        #expect(LibraryCatalog.downloadState(local: nil, starting: false) == .available)
        #expect(LibraryCatalog.downloadState(local: nil, starting: true) == .starting)
        #expect(LibraryCatalog.downloadState(local: downloading, starting: true) == .downloading)
        #expect(LibraryCatalog.downloadState(local: ready, starting: false) == .ready)
        #expect(LibraryCatalog.downloadState(local: failed, starting: false) == .failed("checksum"))
        #expect(LibraryCatalog.downloadState(local: failed, starting: true) == .starting)
        #expect(CatalogDownloadState.downloading.isBusy)
        #expect(CatalogDownloadState.starting.isBusy)
        #expect(!CatalogDownloadState.failed("checksum").isBusy)
        #expect(!CatalogDownloadState.ready.isBusy)
        #expect(CatalogDownloadState.available.buttonTitle == "Download")
        #expect(CatalogDownloadState.ready.buttonTitle == "In Library")
        #expect(CatalogDownloadState.failed("checksum").buttonTitle == "Retry")
        #expect(CatalogDownloadState.starting.buttonTitle == "Starting")
    }

    @Test func `catalog merge keeps previous images when A fetch fails`() {
        let kept = catalogImage(id: "cat-keep", name: "HAOS")
        let next = catalogImage(id: "cat-next", name: "Ubuntu")
        let previous = ["repo-keep": [kept], "repo-gone": [kept]]

        let mixed = LibraryCatalog.mergeCatalogImages(
            previous: previous,
            loads: [
                "repo-keep": .failed,
                "repo-new": .fetched([next]),
                "repo-empty": .fetched([]),
            ],
        )
        #expect(mixed.imagesByRepo["repo-keep"]?.map(\.id) == ["cat-keep"])
        #expect(mixed.imagesByRepo["repo-new"]?.map(\.id) == ["cat-next"])
        #expect(mixed.imagesByRepo["repo-empty"] == nil)
        #expect(mixed.imagesByRepo["repo-gone"] == nil)
        #expect(!mixed.fetchFailed)

        let allFailed = LibraryCatalog.mergeCatalogImages(
            previous: previous,
            loads: ["repo-keep": .failed, "repo-new": .failed],
        )
        #expect(allFailed.imagesByRepo["repo-keep"]?.map(\.id) == ["cat-keep"])
        #expect(allFailed.fetchFailed)
        #expect(
            LibraryCatalog.mergeCatalogImages(previous: [:], loads: ["repo-keep": .failed]).fetchFailed,
        )
        #expect(LibraryCatalog.emptyCatalogMessage(fetchFailed: true) == LibraryCatalog.failedCatalogCopy)
        #expect(LibraryCatalog.emptyCatalogMessage(fetchFailed: false) == LibraryCatalog.emptyCatalogCopy)
    }

    private func snapshot(
        hostId: String,
        role: String,
        title: String? = nil,
        reachable: Bool = true,
    ) -> HomeDeviceHealthSnapshot {
        HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: role,
            displayName: title ?? hostId,
            fingerprint: nil,
            agentHost: nil,
            agentPort: 7_777,
            pairedAt: nil,
            reachability: reachable ? "ok" : "unreachable",
            reachabilityError: reachable ? nil : "Device is unreachable",
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }

    private func catalogImage(id: String, name: String) -> CatalogImage {
        CatalogImage(
            id: id,
            repositoryId: "repo-images",
            slug: name.lowercased(),
            name: name,
            description: nil,
            imageType: "ova",
            arch: "arm64",
            version: "1",
            downloadUrl: "https://example.test/\(id).qcow2",
            sizeBytes: 100,
        )
    }

    private func libraryImage(status: String, sourceUrl: String, error: String? = nil) -> LibraryImage {
        LibraryImage(
            id: "img-\(status)",
            name: "HAOS",
            imageType: "ova",
            arch: "arm64",
            status: status,
            sizeBytes: 100,
            sourceUrl: sourceUrl,
            error: error,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-02T00:00:00Z",
        )
    }
}
