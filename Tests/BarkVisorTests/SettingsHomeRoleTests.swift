import Foundation
import Testing

struct SettingsHomeRoleTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `feature forbids the Settings Home Role fact`() throws {
        let feature = try read("features/settings-home-role.feature")
        #expect(feature.contains("What you can do on this Home"))
        #expect(feature.contains("Home"))
        #expect(feature.contains("Device"))
        #expect(feature.contains("Pairing"))
    }

    @Test func `web Settings Home has no Role fact`() throws {
        let settings = try read("frontend/src/views/SettingsView.vue")
        #expect(settings.contains("v-if=\"tab === 'home'\""))
        #expect(settings.contains("v-if=\"isPairingTab(tab)\""))
        #expect(!settings.contains("What you can do on this Home"))
        #expect(!settings.contains("roleTag"))
        #expect(!settings.contains("roleNote"))
        #expect(!settings.contains("Full control on this Home"))
        #expect(!settings.contains("Standard access on this Home"))
        #expect(settings.contains("isPairingTab"))
        #expect(settings.contains("Phone sign-in"))
        let css = try read("frontend/src/style.css")
        #expect(!css.contains(".role-tag"))
        #expect(!css.contains(".role {"))
    }

    @Test func `console Settings has no Role fact`() throws {
        let source = try read("Apps/BarkVisorConsole/Sources/Views/SettingsView.swift")
        #expect(!source.contains("What you can do on this Home"))
        #expect(!source.contains("Full control on this Home"))
        #expect(!source.contains("Standard access on this Home"))
        #expect(!source.contains("roleTag"))
        #expect(!source.contains("roleNote"))
    }

    @Test func `docs no longer list the Role fact`() throws {
        let docs = [
            "docs/settings-home.md",
            "website/src/content/docs/docs/using/settings/home.md",
        ]
        for path in docs {
            let text = try read(path)
            #expect(!text.contains("**Role**"))
            #expect(!text.contains("what your account can do on this Home"))
            #expect(!text.contains("What you can do on this Home"))
        }
    }
}
