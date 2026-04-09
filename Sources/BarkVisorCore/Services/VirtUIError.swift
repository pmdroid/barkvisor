import Foundation

public enum BarkVisorError: Error, LocalizedError {
    // Domain errors
    case qemuNotFound(String)
    case firmwareNotFound(String)
    case unknownVMType(String)
    case diskCreateFailed(String)
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
    case updateFailed(String)
    case invalidArgument(String)
    case timeout(String)

    // HTTP-semantic errors (used by services to signal status without importing Vapor)
    case badRequest(String)
    case notFound(String? = nil)
    case unauthorized(String? = nil)
    case forbidden(String)
    case conflict(String)
    case preconditionFailed(String)
    case internalError(String)

    /// Full description including paths — for logging only, never send to clients.
    public var errorDescription: String? {
        switch self {
        case let .qemuNotFound(msg): return msg
        case let .firmwareNotFound(msg): return msg
        case let .unknownVMType(t): return "Unknown VM type: \(t)"
        case let .diskCreateFailed(msg): return msg
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
        case let .updateFailed(msg): return msg
        case let .invalidArgument(msg): return msg
        case let .timeout(msg): return msg
        case let .badRequest(msg): return msg
        case let .notFound(msg): return msg ?? "Not found"
        case let .unauthorized(msg): return msg ?? "Unauthorized"
        case let .forbidden(msg): return msg
        case let .conflict(msg): return msg
        case let .preconditionFailed(msg): return msg
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
        case .updateFailed: return "update_failed"
        case .invalidArgument: return "invalid_argument"
        case .timeout: return "timeout"
        case .badRequest: return "bad_request"
        case .notFound: return "not_found"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .conflict: return "conflict"
        case .preconditionFailed: return "precondition_failed"
        case .internalError: return "internal_error"
        }
    }

    /// HTTP status code for the error middleware to use.
    public var httpStatus: UInt {
        switch self {
        case .badRequest, .invalidArgument, .invalidPortForward, .unknownVMType:
            return 400
        case .unauthorized:
            return 401
        case .forbidden:
            return 403
        case .notFound, .repositoryNotFound:
            return 404
        case .conflict, .vmAlreadyRunning:
            return 409
        case .preconditionFailed:
            return 412
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
}
