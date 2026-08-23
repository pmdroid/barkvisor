import Foundation

public enum BarkVisorError: Error, LocalizedError {
    // Domain errors
    case qemuNotFound(String)
    case firmwareNotFound(String)
    case unknownVMType(String)
    case diskCreateFailed(String)
    /// Volume does not have room for the write (HTTP 507).
    case insufficientDiskSpace(freeBytes: Int64, neededBytes: Int64)
    case cloudInitFailed(String)
    case monitorError(String)
    case vmNotRunning(String)
    case vmAlreadyRunning(String)
    case ptyParseFailed
    case processSpawnFailed(String)
    case repositoryNotFound(String)
    case repositorySyncFailed(String)
    case invalidPortForward(String)
    case decompressFailed(String)
    case downloadFailed(String)
    case bridgeNotReady(String)
    /// Host interface does not exist (PAS-57 preflight). HTTP 422 + `interface_missing`.
    case interfaceMissing(String)
    /// qemu-bridge-helper ACL denies this iface. HTTP 422 + `bridge_acl`.
    case bridgeHelperDenied(String)
    /// Bridge / iface name failed IFNAMSIZ or charset checks. HTTP 400 + `invalid_bridge`.
    case invalidBridgeName(String)
    case invalidArgument(String)
    case timeout(String)
    /// Capability block: HTTP 422 + feature `errorCode` (PAS-94).
    case unsupportedFeature(PlatformCapabilities.Feature)

    // HTTP-semantic errors (used by services to signal status without importing Vapor)
    case badRequest(String)
    case notFound(String? = nil)
    case unauthorized(String? = nil)
    case forbidden(String)
    case conflict(String)
    /// Config-vs-config or bind-probe host port collision (PAS-64). HTTP 409 + `port_in_use`.
    case portInUse(String)
    case preconditionFailed(String)
    /// Upstream Ollama (or another Device) did not answer.
    case badGateway(String)
    case internalError(String)

    /// Full description including paths — for logging only, never send to clients.
    public var errorDescription: String? {
        switch self {
        case let .qemuNotFound(msg): return msg
        case let .firmwareNotFound(msg): return msg
        case let .unknownVMType(t): return "Unknown VM type: \(t)"
        case let .diskCreateFailed(msg): return msg
        case let .insufficientDiskSpace(free, needed):
            return "Not enough disk space: \(Self.bytesText(free)) free, need \(Self.bytesText(needed))."
        case let .cloudInitFailed(msg): return msg
        case let .monitorError(msg): return msg
        case let .vmNotRunning(id): return "VM \(id) is not running"
        case let .vmAlreadyRunning(id): return "VM \(id) is already running"
        case .ptyParseFailed: return "Failed to parse PTY path from QEMU output"
        case let .processSpawnFailed(msg): return msg
        case let .repositoryNotFound(id): return "Repository \(id) not found"
        case let .repositorySyncFailed(msg): return msg
        case let .invalidPortForward(msg): return msg
        case let .decompressFailed(msg): return msg
        case let .downloadFailed(msg): return msg
        case let .bridgeNotReady(msg): return msg
        case let .interfaceMissing(name):
            if PlatformHost.platformName.caseInsensitiveCompare("Linux") == .orderedSame {
                return "Host interface '\(name)' does not exist. Create a Linux bridge first "
                    + "(ip link add name \(name) type bridge; ip link set \(name) up) "
                    + "and allow it in the qemu-bridge-helper ACL (bridge.conf). "
                    + "Use NAT if bridging is unavailable."
            }
            return "Host interface '\(name)' does not exist. Choose an existing interface or create it first."
        case let .bridgeHelperDenied(name):
            return "Host bridge '\(name)' is not allowed by the qemu-bridge-helper ACL (bridge.conf). "
                + "Add `allow \(name)` (or `allow all`) and retry, or use NAT."
        case let .invalidBridgeName(msg): return msg
        case let .invalidArgument(msg): return msg
        case let .timeout(msg): return msg
        case let .unsupportedFeature(feature):
            return PlatformCapabilities.unsupportedMessage(feature)
        case let .badRequest(msg): return msg
        case let .notFound(msg): return msg ?? "Not found"
        case let .unauthorized(msg): return msg ?? "Unauthorized"
        case let .forbidden(msg): return msg
        case let .conflict(msg): return msg
        case let .portInUse(msg): return msg
        case let .preconditionFailed(msg): return msg
        case let .badGateway(msg): return msg
        case let .internalError(msg): return msg
        }
    }

    /// Machine-readable error code for frontend handling.
    public var code: String {
        switch self {
        case .qemuNotFound: return "qemu_not_found"
        case .firmwareNotFound: return "firmware_not_found"
        case .unknownVMType: return "unknown_vm_type"
        case .diskCreateFailed: return "disk_create_failed"
        case .insufficientDiskSpace: return "insufficient_disk_space"
        case .cloudInitFailed: return "cloud_init_failed"
        case .monitorError: return "monitor_error"
        case .vmNotRunning: return "vm_not_running"
        case .vmAlreadyRunning: return "vm_already_running"
        case .ptyParseFailed: return "pty_parse_failed"
        case .processSpawnFailed: return "process_spawn_failed"
        case .repositoryNotFound: return "repository_not_found"
        case .repositorySyncFailed: return "repository_sync_failed"
        case .invalidPortForward: return "invalid_port_forward"
        case .decompressFailed: return "decompress_failed"
        case .downloadFailed: return "download_failed"
        case .bridgeNotReady: return "bridge_not_ready"
        case .interfaceMissing: return "interface_missing"
        case .bridgeHelperDenied: return "bridge_acl"
        case .invalidBridgeName: return "invalid_bridge"
        case .invalidArgument: return "invalid_argument"
        case .timeout: return "timeout"
        case let .unsupportedFeature(feature): return feature.errorCode
        case .badRequest: return "bad_request"
        case .notFound: return "not_found"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .conflict: return "conflict"
        case .portInUse: return "port_in_use"
        case .preconditionFailed: return "precondition_failed"
        case .badGateway: return "bad_gateway"
        case .internalError: return "internal_error"
        }
    }

    /// HTTP status code for the error middleware to use.
    public var httpStatus: UInt {
        switch self {
        case .badRequest, .invalidArgument, .invalidPortForward, .unknownVMType, .invalidBridgeName:
            return 400
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .notFound, .repositoryNotFound:
            return 404
        case .conflict, .vmAlreadyRunning, .portInUse:
            return 409
        case .preconditionFailed:
            return 412
        case .unsupportedFeature, .interfaceMissing, .bridgeHelperDenied, .bridgeNotReady:
            return 422
        case .badGateway:
            return 502
        case .insufficientDiskSpace:
            return 507
        default:
            return 500
        }
    }

    /// Client-safe description with filesystem paths stripped.
    public var sanitizedDescription: String {
        let full = errorDescription ?? "Unknown error"
        // Strip absolute paths starting with / followed by common directory names
        return full.replacingOccurrences(
            of:
            #"/(?:Users|home|root|var|tmp|opt|etc|Library|Volumes|Applications|private|nix|snap)[/\w._-]+"#,
            with: "<path>",
            options: .regularExpression,
        )
    }

    private static func bytesText(_ n: Int64) -> String {
        if n >= 1_073_741_824 { return String(format: "%.1f GiB", Double(n) / 1_073_741_824) }
        if n >= 1_048_576 { return String(format: "%.0f MiB", Double(n) / 1_048_576) }
        return "\(n) B"
    }
}
