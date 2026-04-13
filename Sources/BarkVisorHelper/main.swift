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
            let pid = connection.processIdentifier
            let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
                  let code
            else { return false }

            let reqString =
                "anchor apple generic and identifier \"dev.barkvisor.app\" and certificate leaf[subject.OU] = \"\(kHelperTeamID)\""
            var requirement: SecRequirement?
            guard SecRequirementCreateWithString(reqString as CFString, [], &requirement)
                == errSecSuccess,
                let requirement
            else { return false }

            return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
        #endif
    }
}

helperLogger.info("BarkVisorHelper started")

BridgeMonitor.shared.start()

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
