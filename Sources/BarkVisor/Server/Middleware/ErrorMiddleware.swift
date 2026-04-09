import BarkVisorCore
import Vapor

/// Returns structured JSON error responses with error codes.
///
/// Response format:
/// ```json
/// {"error": true, "code": "vm_not_running", "reason": "VM is not running", "status": 500}
/// ```
struct StructuredErrorMiddleware: AsyncMiddleware {
    func respond(to request: Vapor.Request, chainingTo next: any AsyncResponder) async throws
        -> Vapor.Response {
        do {
            return try await next.respond(to: request)
        } catch let abort as Abort {
            if abort.status.code >= 500 {
                Log.server.error("HTTP \(abort.status.code): \(abort.reason)")
            }
            return errorResponse(
                status: abort.status,
                code: httpErrorCode(abort.status),
                reason: abort.reason,
                request: request,
            )
        } catch let bvError as BarkVisorError {
            let status = HTTPResponseStatus(statusCode: Int(bvError.httpStatus))
            if bvError.httpStatus >= 500 {
                Log.server.error("BarkVisorError: \(bvError.errorDescription ?? "unknown")")
            }

            return errorResponse(
                status: status,
                code: bvError.code,
                reason: bvError.sanitizedDescription,
                request: request,
            )
        } catch {
            Log.server.error("Unhandled error: \(error)")

            return errorResponse(
                status: .internalServerError,
                code: "internal_error",
                reason: "An unexpected internal error occurred",
                request: request,
            )
        }
    }

    private func errorResponse(
        status: HTTPResponseStatus, code: String, reason: String, request: Vapor.Request,
    ) -> Response {
        let json =
            "{\"error\":true,\"code\":\(jsonEscape(code)),\"reason\":\(jsonEscape(reason)),\"status\":\(status.code)}"
        var headers = HTTPHeaders()
        headers.contentType = .json
        if let requestId = request.storage[RequestIdKey.self] {
            headers.add(name: "X-Request-Id", value: requestId)
        }
        return Response(status: status, headers: headers, body: .init(string: json))
    }

    private func jsonEscape(_ s: String) -> String {
        // Use JSONEncoder for correct escaping of all control characters and unicode
        if let data = try? JSONEncoder().encode(s),
           let result = String(data: data, encoding: .utf8) {
            return result
        }
        // Fallback: manual escaping
        let escaped =
            s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    private func httpErrorCode(_ status: HTTPResponseStatus) -> String {
        switch status {
        case .badRequest: return "bad_request"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .notFound: return "not_found"
        case .conflict: return "conflict"
        case .tooManyRequests: return "rate_limited"
        case .serviceUnavailable: return "service_unavailable"
        default: return "http_\(status.code)"
        }
    }
}
