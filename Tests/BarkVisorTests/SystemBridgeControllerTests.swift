import Foundation
import Testing
@testable import BarkVisorCore

struct SystemBridgeControllerTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func controllerSource() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent(
                "Sources/BarkVisor/Server/Controllers/System/SystemBridgeController.swift",
            ),
            encoding: .utf8,
        )
    }

    @Test func `POST and DELETE route to linuxApply and macHostApply only`() throws {
        let src = try controllerSource()
        #expect(src.contains("func installBridge"))
        #expect(src.contains("func removeBridge"))
        #expect(src.contains("Self.linuxApply(req: req, defaultAction: .apply)"))
        #expect(src.contains("Self.linuxApply(req: req, defaultAction: .revert)"))
        #expect(src.contains("Self.macHostApply(req: req, defaultAction: .apply)"))
        #expect(src.contains("Self.macHostApply(req: req, defaultAction: .revert)"))
        #expect(src.contains("MacHostBridgeApplyLive.run"))
        #expect(src.contains("LinuxHostBridgeApplyLive.run"))
        #expect(!src.contains("socketVmnetApply"))
        #expect(!src.contains("parseSocketAction"))
        #expect(!src.contains("SocketVmnetApplyLive"))
        #expect(!src.contains("SocketVmnetApplyAction"))
        #expect(!src.contains("cluster"))
        #expect(!src.contains("node"))
        #expect(!src.contains("quorum"))
    }

    @Test func `start and stop reject in favor of apply and revert`() throws {
        let src = try controllerSource()
        #expect(src.contains("Host bridges use apply and revert, not start or stop."))
        #expect(!src.contains("defaultAction: .setup"))
        #expect(!src.contains("defaultAction: .start"))
        #expect(!src.contains("defaultAction: .stop"))
    }
}
