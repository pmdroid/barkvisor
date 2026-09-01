import Foundation
import Testing

struct LibraryDeleteFailedTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `feature covers failed download delete on web Console and owning Device`() throws {
        let feature = try read("features/library-delete-failed.feature")
        #expect(feature.contains("Delete failed image downloads"))
        #expect(feature.contains("error status"))
        #expect(feature.contains("partial file"))
        #expect(feature.contains("Images list"))
        #expect(feature.contains("owning Device"))
        #expect(feature.contains("This Device"))
        #expect(feature.contains("Console"))
        #expect(feature.contains("Library"))
        #expect(!feature.localizedCaseInsensitiveContains("cluster"))
    }

    @Test func `web Images delete routes Home-union rows to the owning Device`() throws {
        let view = try read("frontend/src/views/ImageLibraryView.vue")
        #expect(view.contains("owningMemberDevice"))
        #expect(view.contains("deviceImagePath"))
        #expect(view.contains("deleteImage(img.id, img.name"))
        #expect(view.contains("'hostId' in img ? img.hostId"))
        #expect(view.contains("aria-label=\"Delete\""))
        #expect(!view.contains("img.status === 'ready' &&"))
        #expect(!view.contains("v-if=\"img.status === 'ready'\""))
    }

    @Test func `console Library delete is on error rows and the Device that owns the list`() throws {
        let view = try read("Apps/BarkVisorConsole/Sources/Views/LibraryView.swift")
        #expect(view.contains("image.status == \"error\""))
        #expect(view.contains("deleteLibraryImage"))
        #expect(view.contains("Delete"))
        let model = try read("Apps/BarkVisorConsole/Sources/Services/AppModel.swift")
        #expect(model.contains("deleteImage(image.id, on: libraryDevice)"))
        let client = try read("Apps/BarkVisorConsole/Sources/Services/APIClient.swift")
        #expect(client.contains("func deleteImage(_ id: String, on device: HomeDeviceHealthSnapshot?)"))
        #expect(client.contains("scoped(\"/images/\\(encoded)\", on: device)"))
    }

    @Test func `delete leftover download files for error rows`() throws {
        let service = try read("Sources/BarkVisorCore/Services/ImageService.swift")
        #expect(service.contains("removeLeftoverDownloadFiles"))
        #expect(service.contains("previousDirectories"))
        #expect(service.contains("entry.hasPrefix(\"\\(imageId).\")"))
        let tests = try read("Tests/BarkVisorTests/ImageServiceTests.swift")
        #expect(tests.contains("delete failed download removes row and partial file"))
        #expect(tests.contains("status: \"error\""))
    }
}
