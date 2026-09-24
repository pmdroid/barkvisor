import Foundation

public enum LocalManagementAuthorization {
    public static func decide(
        peer: LocalPeerIdentity,
        request: LocalManagementRequest,
        policy: LocalManagementPolicy,
    ) -> AuthorizationDecision {
        if !LocalManagementCompatibility.accepts(version: request.version) {
            return deny(request, .unsupportedProtocol)
        }
        if !identifiersFit(request) {
            return deny(request, .malformed)
        }
        if !policy.allowedPeerUIDs.contains(peer.uid) {
            return deny(request, .peerNotAllowed)
        }
        if request.name == "protocolVersion" {
            return allow(request, subject: nil)
        }
        guard let token = normalizedToken(request.sessionToken) else {
            if normalizedClaim(request.claimedUserId) != nil {
                return deny(request, .forgedIdentity)
            }
            return deny(request, .missingCredential)
        }
        guard let membership = policy.memberships.first(where: { $0.sessionToken == token }) else {
            return deny(request, .unknownSession)
        }
        if membership.revoked {
            return deny(request, .revokedMember)
        }
        if let claim = normalizedClaim(request.claimedUserId), claim != membership.subject {
            return deny(request, .forgedIdentity)
        }
        if let resource = resourceRejection(request, policy: policy) {
            return deny(request, resource)
        }
        return allow(request, subject: membership.subject)
    }

    public static func pathAllowed(_ path: String, roots: [String]) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return false }
        if parts.contains(where: { $0 == "." || $0 == ".." }) { return false }
        for root in roots {
            if path == root { return true }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if path.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func resourceRejection(
        _ request: LocalManagementRequest,
        policy: LocalManagementPolicy,
    ) -> LocalRejection? {
        if request.name == "openTerminal" {
            guard let uid = request.terminalUID, uid != 0 else {
                return .terminalRootRejected
            }
        }
        for path in request.paths where !pathAllowed(path, roots: policy.resources.allowedRoots) {
            return .invalidPath
        }
        if request.mounts.contains(where: { !policy.resources.allowedMounts.contains($0) }) {
            return .unauthorizedMount
        }
        if request.devices.contains(where: { !policy.resources.allowedDevices.contains($0) }) {
            return .unauthorizedDevice
        }
        if let marker = request.marker, marker.count > LocalManagementLimits.maxMarkerLength {
            return .malformed
        }
        return nil
    }

    private static func identifiersFit(_ request: LocalManagementRequest) -> Bool {
        let limit = LocalManagementLimits.maxIdentifierLength
        guard request.requestId.count <= limit, request.operationId.count <= limit else {
            return false
        }
        guard request.name.count <= limit, !request.name.isEmpty, !request.requestId.isEmpty else {
            return false
        }
        if request.name != "protocolVersion", request.operationId.isEmpty { return false }
        if let token = request.sessionToken, token.count > LocalManagementLimits.maxTokenLength {
            return false
        }
        return true
    }

    private static func normalizedToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return token
    }

    private static func normalizedClaim(_ claim: String?) -> String? {
        guard let claim, !claim.isEmpty else { return nil }
        return claim
    }

    private static func deny(
        _ request: LocalManagementRequest,
        _ reason: LocalRejection,
    ) -> AuthorizationDecision {
        AuthorizationDecision(
            requestId: request.requestId,
            operationId: request.operationId,
            allowed: false,
            reason: reason.rawValue,
        )
    }

    private static func allow(
        _ request: LocalManagementRequest,
        subject: String?,
    ) -> AuthorizationDecision {
        AuthorizationDecision(
            requestId: request.requestId,
            operationId: request.operationId,
            allowed: true,
            reason: "ok",
            subject: subject,
        )
    }
}
