import Foundation
import Testing
@testable import BarkVisor

struct LocalTemplatesCatalogTests {
    @Test func `homebrew share templates.json is found when cwd is data dir`() throws {
        try withCatalogFixture { root in
            let share = root.appendingPathComponent("share/barkvisor")
            let dataDir = root.appendingPathComponent("var/lib/barkvisor")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let catalog = share.appendingPathComponent("templates.json")
            try Data("{}".utf8).write(to: catalog)

            let found = Seeder.localTemplatesCatalogURL(
                shareDir: share.path,
                currentDirectory: dataDir.path,
            )
            #expect(found?.resolvingSymlinksInPath() == catalog.resolvingSymlinksInPath())
        }
    }

    @Test func `shareDir repos templates.json is found when cwd has no checkout`() throws {
        try withCatalogFixture { root in
            let share = root.appendingPathComponent("share/barkvisor")
            let dataDir = root.appendingPathComponent("var/lib/barkvisor")
            let repos = share.appendingPathComponent("repos")
            try FileManager.default.createDirectory(at: repos, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            let catalog = repos.appendingPathComponent("templates.json")
            try Data("{}".utf8).write(to: catalog)

            let found = Seeder.localTemplatesCatalogURL(
                shareDir: share.path,
                currentDirectory: dataDir.path,
            )
            #expect(found?.resolvingSymlinksInPath() == catalog.resolvingSymlinksInPath())
        }
    }

    @Test func `cwd walk still finds checkout repos templates.json`() throws {
        try withCatalogFixture { root in
            let share = root.appendingPathComponent("empty-share")
            let checkout = root.appendingPathComponent("src")
            let nested = checkout.appendingPathComponent("Sources/BarkVisor")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            let catalog = checkout.appendingPathComponent("repos/templates.json")
            try FileManager.default.createDirectory(
                at: catalog.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data("{}".utf8).write(to: catalog)

            let found = Seeder.localTemplatesCatalogURL(
                shareDir: share.path,
                currentDirectory: nested.path,
            )
            #expect(found?.resolvingSymlinksInPath() == catalog.resolvingSymlinksInPath())
        }
    }

    @Test func `installed share copy wins over cwd checkout copy`() throws {
        try withCatalogFixture { root in
            let share = root.appendingPathComponent("share/barkvisor")
            let checkout = root.appendingPathComponent("src")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: checkout.appendingPathComponent("repos"),
                withIntermediateDirectories: true,
            )
            let installed = share.appendingPathComponent("templates.json")
            let checkoutCatalog = checkout.appendingPathComponent("repos/templates.json")
            try Data("{\"installed\":true}".utf8).write(to: installed)
            try Data("{\"checkout\":true}".utf8).write(to: checkoutCatalog)

            let found = Seeder.localTemplatesCatalogURL(
                shareDir: share.path,
                currentDirectory: checkout.path,
            )
            #expect(found?.resolvingSymlinksInPath() == installed.resolvingSymlinksInPath())
        }
    }

    @Test func `brew services cwd without share catalog is a miss`() throws {
        try withCatalogFixture { root in
            let share = root.appendingPathComponent("share/barkvisor")
            let dataDir = root.appendingPathComponent("var/lib/barkvisor")
            try FileManager.default.createDirectory(at: share, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

            let found = Seeder.localTemplatesCatalogURL(
                shareDir: share.path,
                currentDirectory: dataDir.path,
            )
            #expect(found == nil)
        }
    }
}

private func withCatalogFixture(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
