import BarkVisorHelperProtocol
import Foundation
import Logging
import Security
import SwiftSentry

let sentry = try? Sentry(dsn: "https://fd23965cd2644e52116484d7029e900d@o477595.ingest.us.sentry.io/4511210185162752")

LoggingSystem.bootstrap { [sentry] label in
    var handler = StreamLogHandler.standardOutput(label: label)
    handler.logLevel = .debug
    if let sentry {
        return MultiplexLogHandler([
            SentryLogHandler(label: label, sentry: sentry, level: .error),
            handler,
        ])
    }
    return handler
}

var helperLogger = Logger(label: "barkvisor.helper")
helperLogger[metadataKey: "version"] = Logger.MetadataValue(stringLiteral: "1.0.0")

class HelperDelegate: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection,
    ) -> Bool {
        guard verifyConnection(connection) else {
            NSLog(
                "BarkVisorHelper: rejected XPC connection from pid %d", connection.processIdentifier,
            )
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = HelperHandler()
        connection.resume()
        return true
    }

    private func verifyConnection(_ connection: NSXPCConnection) -> Bool {
        #if DEBUG
            return true
        #else
            guard let snapshot = clientSigningSnapshot(pid: connection.processIdentifier) else {
                return false
            }
            let teamRequirement = helperCodeRequirement(
                identifier: kHelperClientIdentifier,
                teamID: kHelperTeamID,
            )
            if secCodeMatches(snapshot.code, requirement: teamRequirement) {
                return true
            }
            guard secCodeMatches(
                snapshot.code,
                requirement: helperClientIdentifierRequirement(),
            ) else {
                return false
            }
            return helperAllowsXPCClient(
                identifier: snapshot.identifier,
                teamID: snapshot.teamID,
                isAdHoc: helperSigningIsAdHoc(teamID: snapshot.teamID, flags: snapshot.flags),
                executablePath: snapshot.path,
                homebrewPrefixes: helperHomebrewPrefixes(
                    extraPrefix: ProcessInfo.processInfo.environment["HOMEBREW_PREFIX"],
                ),
            )
        #endif
    }

    private struct ClientSigningSnapshot {
        let code: SecCode
        let identifier: String?
        let teamID: String?
        let flags: UInt32
        let path: String?
    }

    private func clientSigningSnapshot(pid: pid_t) -> ClientSigningSnapshot? {
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        let copyInfo = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info,
        )
        guard copyInfo == errSecSuccess, let dict = info as? [String: Any] else { return nil }

        let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        let teamID = dict[kSecCodeInfoTeamIdentifier as String] as? String
        let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        var path: CFURL?
        _ = SecCodeCopyPath(staticCode, [], &path)
        return ClientSigningSnapshot(
            code: code,
            identifier: identifier,
            teamID: teamID,
            flags: flags,
            path: (path as URL?)?.path,
        )
    }

    private func secCodeMatches(_ code: SecCode, requirement reqString: String) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqString as CFString, [], &requirement)
            == errSecSuccess,
            let requirement
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

helperLogger.info("BarkVisorHelper started")

BridgeMonitor.shared.start()

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
