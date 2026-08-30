import AuthenticationServices
import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS) || os(macOS)

@MainActor
enum PasskeyAuth {
    enum AuthError: LocalizedError {
        case cancelled
        case missingChallenge
        case missingRPID

        var errorDescription: String? {
            switch self {
            case .cancelled: "Passkey sign-in was cancelled"
            case .missingChallenge: "Invalid passkey challenge from the Device"
            case .missingRPID: "Invalid passkey options from the Device"
            }
        }
    }

    static func performLogin(publicKey: [String: Any]) async throws -> [String: Any] {
        guard let challengeString = publicKey["challenge"] as? String,
              let challenge = PasskeySupport.dataFromBase64url(challengeString)
        else { throw AuthError.missingChallenge }
        let rpID = (publicKey["rpId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rpID, !rpID.isEmpty else { throw AuthError.missingRPID }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpID)
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required

        let controller = ASAuthorizationController(authorizationRequests: [request])
        let delegate = ControllerDelegate()
        controller.delegate = delegate
        controller.presentationContextProvider = delegate

        let credential = try await delegate.perform(controller: controller)
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw AuthError.cancelled
        }
        return PasskeySupport.assertionCredentialJSON(
            id: PasskeySupport.base64urlFromData(assertion.credentialID),
            rawID: assertion.credentialID,
            clientDataJSON: assertion.rawClientDataJSON,
            authenticatorData: assertion.rawAuthenticatorData,
            signature: assertion.signature,
            userHandle: assertion.userID,
        )
    }

    @MainActor
    private final class ControllerDelegate: NSObject, ASAuthorizationControllerDelegate,
        ASAuthorizationControllerPresentationContextProviding
    {
        private var continuation: CheckedContinuation<ASAuthorizationCredential, Error>?

        func perform(controller: ASAuthorizationController) async throws -> ASAuthorizationCredential {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                controller.performRequests()
            }
        }

        func authorizationController(
            controller _: ASAuthorizationController,
            didCompleteWithAuthorization authorization: ASAuthorization,
        ) {
            continuation?.resume(returning: authorization.credential)
            continuation = nil
        }

        func authorizationController(controller _: ASAuthorizationController, didCompleteWithError error: Error) {
            if (error as NSError).code == ASAuthorizationError.canceled.rawValue {
                continuation?.resume(throwing: PasskeyAuth.AuthError.cancelled)
            } else {
                continuation?.resume(throwing: error)
            }
            continuation = nil
        }

        func presentationAnchor(for _: ASAuthorizationController) -> ASPresentationAnchor {
            #if os(macOS)
                return NSApplication.shared.windows.first { $0.isKeyWindow }
                    ?? NSApplication.shared.windows.first
                    ?? ASPresentationAnchor()
            #else
                let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                return scenes.flatMap(\.windows).first { $0.isKeyWindow }
                    ?? scenes.flatMap(\.windows).first
                    ?? UIWindow()
            #endif
        }
    }
}

#endif
