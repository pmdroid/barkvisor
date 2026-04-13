import Foundation
import Testing
@testable import BarkVisor
@testable import BarkVisorCore

/// Tests for the StructuredErrorMiddleware JSON escape logic
/// and the BarkVisorError HTTP status mapping.
@Suite struct ErrorMiddlewareTests {
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

    @Test func jsonEscapePlainString() {
        #expect(jsonEscape("hello") == "\"hello\"")
    }

    @Test func jsonEscapeQuotes() {
        #expect(jsonEscape("say \"hello\"") == "\"say \\\"hello\\\"\"")
    }

    @Test func jsonEscapeBackslash() {
        #expect(jsonEscape("path\\to\\file") == "\"path\\\\to\\\\file\"")
    }

    @Test func jsonEscapeNewlines() {
        #expect(jsonEscape("line1\nline2") == "\"line1\\nline2\"")
        #expect(jsonEscape("line1\rline2") == "\"line1\\rline2\"")
    }

    @Test func jsonEscapeTab() {
        #expect(jsonEscape("col1\tcol2") == "\"col1\\tcol2\"")
    }

    @Test func jsonEscapeEmpty() {
        #expect(jsonEscape("") == "\"\"")
    }

    @Test func jsonEscapeCombined() {
        let input = "Error: \"file\\not\\found\"\nPlease\tretry"
        let result = jsonEscape(input)
        // Verify it produces valid JSON string content
        #expect(result.hasPrefix("\""))
        #expect(result.hasSuffix("\""))
        // Verify no unescaped control chars remain
        let inner = String(result.dropFirst().dropLast())
        #expect(!inner.contains("\n"))
        #expect(!inner.contains("\r"))
        #expect(!inner.contains("\t"))
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

    @Test func httpErrorCodeMapping() {
        #expect(httpErrorCode(400) == "bad_request")
        #expect(httpErrorCode(401) == "unauthorized")
        #expect(httpErrorCode(403) == "forbidden")
        #expect(httpErrorCode(404) == "not_found")
        #expect(httpErrorCode(409) == "conflict")
        #expect(httpErrorCode(429) == "rate_limited")
        #expect(httpErrorCode(503) == "service_unavailable")
    }

    @Test func httpErrorCodeDefaultFallback() {
        #expect(httpErrorCode(500) == "http_500")
        #expect(httpErrorCode(502) == "http_502")
        #expect(httpErrorCode(418) == "http_418")
    }

    // MARK: - Error Response JSON Structure

    @Test func errorResponseJSONStructure() throws {
        // Verify the JSON template produces valid JSON
        let code = jsonEscape("bad_request")
        let reason = jsonEscape("Name is required")
        let status: UInt = 400
        let json = "{\"error\":true,\"code\":\(code),\"reason\":\(reason),\"status\":\(status)}"

        let data = try #require(json.data(using: .utf8))
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed != nil)
        #expect(parsed?["error"] as? Bool == true)
        #expect(parsed?["code"] as? String == "bad_request")
        #expect(parsed?["reason"] as? String == "Name is required")
        #expect(parsed?["status"] as? Int == 400)
    }

    @Test func errorResponseWithSpecialCharsInReason() throws {
        // Ensure special chars in reason don't break JSON structure
        let reason = jsonEscape("Invalid value: \"foo\\bar\"\nExpected: number")
        let json = "{\"error\":true,\"code\":\"bad_request\",\"reason\":\(reason),\"status\":400}"

        let data = try #require(json.data(using: .utf8))
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(parsed != nil, "JSON with escaped special chars should be parseable")
        #expect(parsed?["reason"] as? String == "Invalid value: \"foo\\bar\"\nExpected: number")
    }
}
