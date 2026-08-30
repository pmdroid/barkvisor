import Foundation
import Testing
@testable import BarkVisorConsole

struct AuditLogTests {
    private let decoder = JSONDecoder()

    @Test func `audit log response decodes entries and total`() throws {
        let json = """
        {
          "entries": [
            {
              "id": 41,
              "timestamp": "2026-08-20T15:04:05Z",
              "userId": "u1",
              "username": "admin",
              "action": "vm.start",
              "resourceType": "vm",
              "resourceId": "vm-1",
              "resourceName": "haos",
              "detail": "Started from the console",
              "authMethod": "jwt",
              "apiKeyId": null
            },
            {
              "id": 40,
              "timestamp": "2026-08-20T14:00:00.000Z",
              "username": null,
              "action": "auth.login",
              "resourceType": null,
              "resourceName": null,
              "detail": null
            }
          ],
          "total": 87
        }
        """.data(using: .utf8)!
        let page = try decoder.decode(AuditLogResponse.self, from: json)
        #expect(page.total == 87)
        #expect(page.entries.count == 2)
        let first = page.entries[0]
        #expect(first.id == 41)
        #expect(first.timestamp == "2026-08-20T15:04:05Z")
        #expect(first.username == "admin")
        #expect(first.action == "vm.start")
        #expect(first.resourceType == "vm")
        #expect(first.resourceName == "haos")
        #expect(first.detail == "Started from the console")
        let second = page.entries[1]
        #expect(second.username == nil)
        #expect(second.resourceType == nil)
        #expect(second.resourceName == nil)
        #expect(second.detail == nil)
        #expect(AuditLogDisplay.timestampLabel(first.timestamp) == "2026-08-20 15:04")
        #expect(AuditLogDisplay.timestampLabel(second.timestamp) == "2026-08-20 14:00")
        #expect(AuditLogDisplay.timestampLabel("not-a-date") == "not-a-date")
        #expect(AuditLogDisplay.resourceLabel(first) == "vm · haos")
        #expect(AuditLogDisplay.resourceLabel(second) == nil)
    }

    @Test func `audit log empty page decodes and reports empty copy`() throws {
        let json = """
        { "entries": [], "total": 0 }
        """.data(using: .utf8)!
        let page = try decoder.decode(AuditLogResponse.self, from: json)
        #expect(page.entries.isEmpty)
        #expect(page.total == 0)
        #expect(AuditLogDisplay.emptyCopy(filtered: false) == "No audit log entries.")
        #expect(AuditLogDisplay.emptyCopy(filtered: true).contains("matching"))
        #expect(AuditLogDisplay.pageCount(total: 0) == 1)
        #expect(AuditLogDisplay.pageCount(total: AuditLogDisplay.pageSize) == 1)
        #expect(AuditLogDisplay.pageCount(total: AuditLogDisplay.pageSize + 1) == 2)
    }

    @Test func `audit log forbidden uses reason then fallback like api keys`() {
        let reason = APIError.http(
            status: 403,
            reason: "Inference callers can list models and call chat completions only",
        )
        #expect(
            AuditLogDisplay.forbiddenMessage(from: reason)
                == "Inference callers can list models and call chat completions only",
        )
        #expect(
            AuditLogDisplay.forbiddenMessage(from: APIError.http(status: 403, reason: "  "))
                == AuditLogDisplay.forbiddenFallback,
        )
        #expect(
            AuditLogDisplay.forbiddenMessage(from: APIError.http(status: 403, reason: "Admin only"))
                == "Admin only",
        )
        #expect(AuditLogDisplay.forbiddenFallback != APIKeyDisplay.forbiddenFallback)
    }

    @Test func `audit log non 403 errors are not forbidden`() {
        #expect(AuditLogDisplay.forbiddenMessage(from: APIError.http(status: 500, reason: "boom")) == nil)
        #expect(AuditLogDisplay.forbiddenMessage(from: APIError.http(status: 401, reason: "nope")) == nil)
        #expect(AuditLogDisplay.forbiddenMessage(from: APIError.unauthorized) == nil)
        #expect(AuditLogDisplay.forbiddenMessage(from: APIError.transport("offline")) == nil)
        #expect(AuditLogDisplay.forbiddenMessage(from: APIError.decoding("bad json")) == nil)
    }

    @Test func `audit log query carries limit offset and optional filters`() {
        let bare = AuditLogQuery.items(limit: 25, offset: 50)
        #expect(bare.map(\.name) == ["limit", "offset"])
        #expect(bare.map(\.value) == ["25", "50"])
        let filtered = AuditLogQuery.items(limit: 25, offset: 0, action: "vm.start", resourceType: "vm")
        #expect(filtered.map(\.name) == ["limit", "offset", "action", "resourceType"])
        #expect(filtered.map(\.value) == ["25", "0", "vm.start", "vm"])
        let emptyFilters = AuditLogQuery.items(limit: 25, offset: 0, action: "", resourceType: nil)
        #expect(emptyFilters.map(\.name) == ["limit", "offset"])
        #expect(AuditLogRoutes.collection == "/api/audit-log")
    }

    @Test func `settings view wires the audit log section`() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/Views/SettingsView.swift"),
            encoding: .utf8,
        )
        #expect(source.contains("AuditLogSection()"))
    }
}
