import Foundation

/// Pairing handshake failures (PAS-45).
public enum PairingError: Error, LocalizedError, Sendable, Equatable {
    case invalidCode
    case expiredOrUsed
    case invalidPayload(String)
    case incompatibleAPIVersion(got: Int, expected: Int)
    case selfPair
    case invalidDeviceCertificate(String)
    case invalidCSR(String)
    case unavailable(String)
    case fingerprintMismatch
    case redeemFailed(status: Int, reason: String)
    case noActiveOffer

    public var errorDescription: String? {
        switch self {
        case .invalidCode, .expiredOrUsed:
            return "Invalid or expired pairing code"
        case let .invalidPayload(reason):
            return reason
        case let .incompatibleAPIVersion(got, expected):
            return "Incompatible API version \(got) (this Device is \(expected))"
        case .selfPair:
            return "Cannot pair a Device with itself"
        case let .invalidDeviceCertificate(reason):
            return "Invalid Device certificate: \(reason)"
        case let .invalidCSR(reason):
            return "Invalid certificate signing request: \(reason)"
        case let .unavailable(reason):
            return reason
        case .fingerprintMismatch:
            return "Issuer fingerprint does not match the pairing code"
        case let .redeemFailed(_, reason):
            return reason
        case .noActiveOffer:
            return "No active pairing code"
        }
    }

    public var barkVisorError: BarkVisorError {
        switch self {
        case .invalidCode, .expiredOrUsed:
            return .unauthorized(errorDescription)
        case .invalidPayload, .invalidDeviceCertificate, .invalidCSR:
            return .badRequest(errorDescription ?? "Invalid pairing request")
        case .incompatibleAPIVersion:
            return .preconditionFailed(errorDescription ?? "Incompatible API version")
        case .selfPair:
            return .conflict(errorDescription ?? "Cannot pair a Device with itself")
        case .unavailable, .redeemFailed:
            return .internalError(errorDescription ?? "Pairing is temporarily unavailable")
        case .fingerprintMismatch:
            return .preconditionFailed(
                errorDescription ?? "Issuer fingerprint does not match the pairing code",
            )
        case .noActiveOffer:
            return .notFound(errorDescription)
        }
    }

    public var httpStatus: UInt {
        switch self {
        case .unavailable:
            return 503
        case let .redeemFailed(status, _):
            return (400 ... 599).contains(status) ? UInt(status) : 502
        default:
            return barkVisorError.httpStatus
        }
    }
}
