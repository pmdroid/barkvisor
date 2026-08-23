import Foundation

/// LaunchDaemon user/group for the BarkVisor service process.
public let kHelperServiceUser = "_barkvisor"

/// Bridged `socket_vmnet` sockets are group-accessible to the service account, not world-writable.
public let kHelperBridgeSocketMode = 0o660

/// Code-signing identifier for bundled `socket_vmnet` (set at release sign time).
public let kHelperSocketVmnetIdentifier = "socket_vmnet"

public func helperCodeRequirement(identifier: String, teamID: String) -> String {
    "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
}
