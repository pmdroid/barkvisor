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
        #expect(!wxs.contains("payload\\*.dll"))
        #expect(!wxs.contains("Source=\"*.dll\""))
        #expect(wxs.contains("ComponentGroupRef Id=\"BarkVisorRuntimeDlls\""))
        #expect(wxs.contains("ComponentGroupRef Id=\"BarkVisorSpaFiles\""))
        #expect(wxs.contains("Platform=\"x64\""))
        #expect(wxs.contains("Win64=\"yes\""))
        let harvest = try read("packaging/windows/harvest-wxs.ps1")
        #expect(harvest.contains("BarkVisorRuntimeDlls"))
        #expect(harvest.contains("BarkVisorSpaFiles"))
        #expect(harvest.contains("Get-ChildItem"))
        #expect(harvest.contains("-Filter *.dll"))
        #expect(harvest.contains("<File Id="))
        #expect(harvest.contains("frontend\\dist"))
        #expect(harvest.contains("Append-SpaDirectory"))
        #expect(harvest.contains("Win64="))
        #expect(!harvest.contains(#"Source="payload\*.dll""#))
        let build = try read("packaging/windows/build-msi.ps1")
        #expect(build.contains("harvest-wxs.ps1"))
        #expect(build.contains("barkvisor-runtime.wxs"))
        #expect(build.contains("barkvisor-spa.wxs"))
        #expect(build.contains("-arch x64"))
    }

    @Test func `windows serves spa without nio filesystem stat`() throws {
        let server = try read("Sources/BarkVisor/Server/VaporServer.swift")
        #expect(server.contains("FoundationStaticFileMiddleware"))
        #expect(server.contains("#if os(Windows)"))
        #expect(server.contains("FileMiddleware("))
        #expect(server.contains("appendingPathComponent(\"share\")"))
        let files = try read("Sources/BarkVisor/Server/Middleware/FoundationStaticFileMiddleware.swift")
        #expect(files.contains("Data(contentsOf:"))
        #expect(files.contains("contains(\"..\")"))
        let logs = try read("Sources/BarkVisor/Server/Controllers/LogController.swift")
        #expect(logs.contains("#if os(Windows)"))
        #expect(logs.contains("Data(contentsOf:"))
        #expect(logs.contains("asyncStreamFile"))
    }

    @Test func `windows payload stages swift runtime and vcruntime dlls`() throws {
        let stage = try read("scripts/stage-windows-payload.ps1")
        #expect(stage.contains("swiftCore.dll"))
        #expect(stage.contains("msvcp140.dll"))
        #expect(stage.contains("vcruntime140.dll"))
        #expect(stage.contains("*Concurrency*.dll"))
        #expect(stage.contains("Runtimes"))
        #expect(stage.contains("missing runtime DLL"))
        #expect(stage.contains("VC\\Redist\\MSVC"))
        let workflow = try read(".github/workflows/windows-package.yml")
        #expect(workflow.contains("stage-windows-payload.ps1"))
        #expect(workflow.contains("swiftCore.dll"))
        #expect(workflow.contains("share\\barkvisor\\frontend\\dist\\index.html"))
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
