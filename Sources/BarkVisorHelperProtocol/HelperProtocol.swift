import Foundation

public let kHelperMachServiceName = "dev.barkvisor.helper"

/// Apple Team ID used for XPC connection verification.
/// In DEBUG builds this defaults to "DEVELOPMENT" (the helper skips
/// code-signing checks anyway).  For release builds, build-release.sh
/// injects the real value via sed before compiling.
/// INJECT_TEAM_ID
public let kHelperTeamID = "W363QN58YY"

@objc public protocol HelperProtocol {
    func getVersion(reply: @escaping (String) -> Void)
    func ping(reply: @escaping (String) -> Void)

    /// Install a socket_vmnet bridged daemon for the given interface.
    func installBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    )

    /// Remove (unload and delete) a socket_vmnet bridged daemon.
    func removeBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    )

    /// Start (bootstrap) an already-installed bridge daemon.
    func startBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    )

    /// Stop (bootout) a running bridge daemon without removing the plist.
    func stopBridge(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    )

    /// Check whether a bridge daemon is currently loaded/running.
    func bridgeStatus(
        interface: String,
        reply: @escaping (Bool, String?) -> Void,
    )

    /// Return all bridge states as a JSON string.
    /// Each element: { interface, socketPath, plistExists, daemonRunning, status }
    func getAllBridgeStates(reply: @escaping (String) -> Void)

    /// Install a software update from a signed PKG file.
    /// Verifies code signature, notarization, and team ID before running the installer.
    /// The reply may never arrive if the postinstall script restarts this process.
    func installUpdate(
        packagePath: String,
        expectedVersion: String,
        reply: @escaping (Bool, String?) -> Void,
    )
}
