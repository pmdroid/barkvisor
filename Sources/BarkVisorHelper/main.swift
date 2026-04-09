import BarkVisorHelperProtocol
import Foundation
import Security
import Sentry

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

SentrySDK.start { options in
    options.dsn =
        "https://d5e5eb34a4353cb69a861084a2c9e522@o477595.ingest.us.sentry.io/4511188107788288"
    options.debug = true
    options.sendDefaultPii = false
}

BridgeMonitor.shared.start()

let delegate = HelperDelegate()
let listener = NSXPCListener(machServiceName: kHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
