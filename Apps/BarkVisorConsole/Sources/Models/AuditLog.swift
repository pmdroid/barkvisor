import Foundation

/// Read-only admin list. Matches SPA `GET /api/audit-log`.
enum AuditLogRoutes {
    static let collection = "/api/audit-log"
}

/// List row DTO. Matches web `AuditEntry` from `AuditController.list`.
struct AuditLogEntry: Decodable, Identifiable, Hashable {
    var id: Int
    var timestamp: String
    var username: String?
    var action: String
    var resourceType: String?
    var resourceName: String?
    var detail: String?
}

/// Page envelope from `AuditController`: `{ entries, total }`.
struct AuditLogResponse: Decodable, Hashable {
    var entries: [AuditLogEntry]
    var total: Int
}

/// Query for `GET /api/audit-log`: limit/offset, optional action/resourceType.
enum AuditLogQuery {
    static func items(
        limit: Int,
        offset: Int,
        action: String? = nil,
        resourceType: String? = nil,
    ) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let action, !action.isEmpty {
            items.append(URLQueryItem(name: "action", value: action))
        }
        if let resourceType, !resourceType.isEmpty {
            items.append(URLQueryItem(name: "resourceType", value: resourceType))
        }
        return items
    }
}

enum AuditLogDisplay {
    static let forbiddenFallback = "Audit log is admin-only."
    static let pageSize = 25

    private static let shortDateTime = posixFormatter("yyyy-MM-dd HH:mm")

    /// Same 403 path as API keys; only the empty-reason fallback differs.
    static func forbiddenMessage(from error: Error) -> String? {
        APIKeyDisplay.forbiddenMessage(from: error, fallback: forbiddenFallback)
    }

    static func emptyCopy(filtered: Bool) -> String {
        filtered ? "No audit log entries matching the filter." : "No audit log entries."
    }

    static func timestampLabel(_ raw: String) -> String {
        guard let date = APIKeyDisplay.parseISO8601(raw) else { return raw }
        return shortDateTime.string(from: date)
    }

    static func resourceLabel(_ entry: AuditLogEntry) -> String? {
        let type = entry.resourceType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = entry.resourceName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if type.isEmpty { return name.isEmpty ? nil : name }
        return name.isEmpty ? type : "\(type) · \(name)"
    }

    static func pageCount(total: Int, pageSize: Int = AuditLogDisplay.pageSize) -> Int {
        max(1, Int(ceil(Double(total) / Double(pageSize))))
    }

    private static func posixFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }
}
