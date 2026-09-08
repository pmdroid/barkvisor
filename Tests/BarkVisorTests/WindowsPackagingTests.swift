import Foundation
import Testing
@testable import BarkVisorCore

struct WindowsPackagingTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    @Test func `msi layout uses program files and programdata`() throws {
        let wxs = try read("packaging/windows/barkvisor.wxs")
        #expect(wxs.contains("ProgramFiles64Folder"))
        #expect(wxs.contains("Name=\"BarkVisor\""))
        #expect(wxs.contains("CommonAppDataFolder"))
        #expect(wxs.contains("Name=\"run\""))
        #expect(wxs.contains("Account=\"LocalSystem\""))
        #expect(wxs.contains("QEMU is missing"))
        #expect(wxs.contains("qemu-system-x86_64.exe"))
        #expect(!wxs.contains("Authenticode"))
        #expect(!wxs.contains("Hyper-V"))
        #expect(!wxs.contains("WSL2"))
        #expect(wxs.contains("CreateFolder"))
        #expect(wxs.contains("frontend\\dist\\index.html"))
        #expect(wxs.contains("payload\\*.dll") || wxs.contains("*.dll"))
        #expect(wxs.contains("BarkVisorSpa"))
    }

    @Test func `install script fails without qemu and uses localsystem`() throws {
        let install = try read("packaging/windows/install.ps1")
        #expect(install.contains("ProgramFiles"))
        #expect(install.contains("ProgramData"))
        #expect(install.contains("qemu-system-x86_64.exe"))
        #expect(install.contains("QEMU is missing"))
        #expect(install.contains("obj= LocalSystem"))
        #expect(install.contains("NT AUTHORITY\\SYSTEM"))
        #expect(install.contains("index.html"))
        #expect(install.contains("frontend\\dist"))
        #expect(install.contains("*.dll"))
        #expect(install.contains("Wait-BarkVisorServiceRemoved"))
        #expect(install.contains("Start-Sleep"))
        #expect(!install.contains("Authenticode"))
        let uninstall = try read("packaging/windows/uninstall.ps1")
        #expect(uninstall.contains("qemu-system"))
        #expect(uninstall.contains("PurgeData"))
        #expect(uninstall.contains("ProgramData"))
        #expect(uninstall.contains("Wait-BarkVisorServiceRemoved"))
    }

    @Test func `service stop handles scm stop not only console`() throws {
        let main = try read("Sources/BarkVisorApp/main.swift")
        #expect(main.contains("SERVICE_CONTROL_STOP"))
        #expect(main.contains("StartServiceCtrlDispatcherW"))
        #expect(main.contains("SERVICE_ACCEPT_STOP"))
        #expect(main.contains("SERVICE_START_PENDING"))
        #expect(main.contains("WindowsService.attach()"))
        #expect(main.contains("WindowsService.reportRunning()"))
        #expect(main.contains("WindowsService.reportStartFailed()"))
        #expect(main.contains("WindowsService.notifyStopped()"))
        #expect(main.contains("windowsServiceDispatcherDone"))
    }

    @Test func `persist private file still 0600 on posix`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Config.persistJWTSecret("secret", to: dir)
        try PrivateFileAccess.restrict(path: Config.jwtSecretFile(in: dir).path)
        let attrs = try FileManager.default.attributesOfItem(
            atPath: Config.jwtSecretFile(in: dir).path,
        )
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        #expect(perms & 0o777 == 0o600)
    }
}
