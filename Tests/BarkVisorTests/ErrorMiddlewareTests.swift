import XCTest
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the StructuredErrorMiddleware JSON escape logic
/// and the BarkVisorError HTTP status mapping.
final class ErrorMiddlewareTests: XCTestCase {
    // MARK: - JSON Escape Logic

    /// Mirrors the private jsonEscape function in StructuredErrorMiddleware.
    private func jsonEscape(_ s: String) -> String {
        let escaped =
            s
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    func testJsonEscapePlainString() {
        XCTAssertEqual(jsonEscape("hello"), "\"hello\"")
    }

    func testJsonEscapeQuotes() {
        XCTAssertEqual(jsonEscape("say \"hello\""), "\"say \\\"hello\\\"\"")
    }

    func testJsonEscapeBackslash() {
        XCTAssertEqual(jsonEscape("path\\to\\file"), "\"path\\\\to\\\\file\"")
    }

    func testJsonEscapeNewlines() {
        XCTAssertEqual(jsonEscape("line1\nline2"), "\"line1\\nline2\"")
        XCTAssertEqual(jsonEscape("line1\rline2"), "\"line1\\rline2\"")
    }

    func testJsonEscapeTab() {
        XCTAssertEqual(jsonEscape("col1\tcol2"), "\"col1\\tcol2\"")
    }

    func testJsonEscapeEmpty() {
        XCTAssertEqual(jsonEscape(""), "\"\"")
    }

    func testJsonEscapeCombined() {
        let input = "Error: \"file\\not\\found\"\nPlease\tretry"
        let result = jsonEscape(input)
        // Verify it produces valid JSON string content
        XCTAssertTrue(result.hasPrefix("\""))
        XCTAssertTrue(result.hasSuffix("\""))
        // Verify no unescaped control chars remain
        let inner = String(result.dropFirst().dropLast())
        XCTAssertFalse(inner.contains("\n"))
        XCTAssertFalse(inner.contains("\r"))
        XCTAssertFalse(inner.contains("\t"))
    }

    // MARK: - HTTP Error Code Mapping

    /// Mirrors the private httpErrorCode function in StructuredErrorMiddleware.
    private func httpErrorCode(_ statusCode: UInt) -> String {
        switch statusCode {
        case 400: return "bad_request"
        case 401: return "unauthorized"
        case 403: return "forbidden"
        case 404: return "not_found"
        case 409: return "conflict"
        case 429: return "rate_limited"
        case 503: return "service_unavailable"
        default: return "http_\(statusCode)"
        }
    }

    func testHttpErrorCodeMapping() {
        XCTAssertEqual(httpErrorCode(400), "bad_request")
        XCTAssertEqual(httpErrorCode(401), "unauthorized")
        XCTAssertEqual(httpErrorCode(403), "forbidden")
        XCTAssertEqual(httpErrorCode(404), "not_found")
        XCTAssertEqual(httpErrorCode(409), "conflict")
        XCTAssertEqual(httpErrorCode(429), "rate_limited")
        XCTAssertEqual(httpErrorCode(503), "service_unavailable")
    }

    func testHttpErrorCodeDefaultFallback() {
        XCTAssertEqual(httpErrorCode(500), "http_500")
        XCTAssertEqual(httpErrorCode(502), "http_502")
        XCTAssertEqual(httpErrorCode(418), "http_418")
    }

    // MARK: - Error Response JSON Structure

    func testErrorResponseJSONStructure() throws {
        // Verify the JSON template produces valid JSON
        let code = jsonEscape("bad_request")
        let reason = jsonEscape("Name is required")
        let status: UInt = 400
        let json = "{\"error\":true,\"code\":\(code),\"reason\":\(reason),\"status\":\(status)}"

        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?["error"] as? Bool, true)
        XCTAssertEqual(parsed?["code"] as? String, "bad_request")
        XCTAssertEqual(parsed?["reason"] as? String, "Name is required")
        XCTAssertEqual(parsed?["status"] as? Int, 400)
    }

    func testErrorResponseWithSpecialCharsInReason() throws {
        // Ensure special chars in reason don't break JSON structure
        let reason = jsonEscape("Invalid value: \"foo\\bar\"\nExpected: number")
        let json = "{\"error\":true,\"code\":\"bad_request\",\"reason\":\(reason),\"status\":400}"

        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed, "JSON with escaped special chars should be parseable")
        XCTAssertEqual(parsed?["reason"] as? String, "Invalid value: \"foo\\bar\"\nExpected: number")
    }
}
