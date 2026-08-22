import Foundation
import Testing
@testable import BarkVisorCore

struct HomeLibraryTests {
    private func image(
        id: String,
        name: String,
        sha256: String? = nil,
        sourceUrl: String? = nil,
        sizeBytes: Int64? = 1_024,
        status: String = "ready",
        arch: String = "arm64",
    ) -> HomeLibraryDeviceImage {
        HomeLibraryDeviceImage(
            id: id,
            name: name,
            imageType: "iso",
            arch: arch,
            status: status,
            sizeBytes: sizeBytes,
            sourceUrl: sourceUrl,
            error: nil,
            sha256: sha256,
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
        )
    }

    @Test func `checksum key wins over name`() {
        let a = image(id: "a", name: "ubuntu.iso", sha256: "abc")
        let b = image(id: "b", name: "ubuntu.iso", sha256: "abc")
        #expect(HomeLibraryCatalog.key(for: a) == "sha256:abc")
        #expect(HomeLibraryCatalog.key(for: a) == HomeLibraryCatalog.key(for: b))
    }

    @Test func `distinct files with the same name do not collapse`() {
        let a = image(id: "iso-a", name: "ubuntu.iso")
        let b = image(id: "iso-b", name: "ubuntu.iso")
        #expect(HomeLibraryCatalog.key(for: a) == "id:iso-a")
        #expect(HomeLibraryCatalog.key(for: b) == "id:iso-b")
    }

    @Test func `size and sourceUrl key when checksum is missing`() {
        let a = image(
            id: "a", name: "cloud.img",
            sourceUrl: "https://example.invalid/cloud.img", sizeBytes: 9,
        )
        let b = image(
            id: "b", name: "cloud.img",
            sourceUrl: "https://example.invalid/cloud.img", sizeBytes: 9,
        )
        #expect(HomeLibraryCatalog.key(for: a) == HomeLibraryCatalog.key(for: b))
        #expect(HomeLibraryCatalog.key(for: a).hasPrefix("iso:arm64:cloud.img:9:"))
    }

    @Test func `merge unions copies across Devices and prefers ready metadata`() throws {
        let downloading = image(id: "local-1", name: "ubuntu.iso", sha256: "abc", status: "downloading")
        let ready = image(id: "peer-1", name: "ubuntu.iso", sha256: "abc", status: "ready")
        let extra = image(id: "peer-x86", name: "debian.iso", arch: "x86_64")
        let merged = HomeLibraryCatalog.merge([
            (hostId: "desk", images: [downloading]),
            (hostId: "studio", images: [ready, extra]),
        ])
        #expect(merged.map(\.name).sorted() == ["debian.iso", "ubuntu.iso"])
        let ubuntu = try #require(merged.first { $0.name == "ubuntu.iso" })
        #expect(ubuntu.status == "ready")
        #expect(ubuntu.id == "peer-1")
        #expect(ubuntu.copies.count == 2)
        #expect(ubuntu.sourceHostIds == ["studio"])
        #expect(HomeLibraryCatalog.sourceCopy(of: ubuntu, excluding: "desk")?.hostId == "studio")
        #expect(HomeLibraryCatalog.sourceCopy(of: ubuntu, excluding: "studio") == nil)
    }

    @Test func `from VMImage drops the local path`() throws {
        let row = VMImage(
            id: "img-1", name: "Ubuntu", imageType: "cloud-image", arch: "arm64",
            path: "/secret/images/img-1.qcow2", sizeBytes: 64,
            status: "ready", error: nil,
            sourceUrl: "https://example.invalid/ubuntu.qcow2",
            sha256: "deadbeef",
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
        )
        let meta = HomeLibraryDeviceImage(from: row)
        #expect(meta.id == "img-1")
        #expect(meta.sha256 == "deadbeef")
        let encoded = try JSONEncoder().encode(meta)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("/secret/images"))
    }
}
