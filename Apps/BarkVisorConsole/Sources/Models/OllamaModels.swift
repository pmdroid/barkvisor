import Foundation

struct OllamaHomeCatalog: Decodable, Equatable {
    var anyReachable: Bool
    var anyInstalled: Bool
    var models: [OllamaCatalogModel]
    var devices: [OllamaDeviceStatus]
}

struct OllamaCatalogModel: Decodable, Identifiable, Equatable, Hashable {
    var name: String
    var digest: String?
    var size: Int64?
    var running: Bool
    var locations: [OllamaModelLocation]

    var id: String { name }

    func matchesName(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return true }
        return name.localizedCaseInsensitiveContains(q)
    }

    var locationLine: String {
        locations.map { loc in
            let trimmed = loc.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = trimmed.isEmpty ? loc.hostId : trimmed
            return loc.running ? "\(name) (running)" : name
        }
        .joined(separator: ", ")
    }
}

struct OllamaModelLocation: Decodable, Equatable, Hashable {
    var hostId: String
    var displayName: String?
    var running: Bool
    var reachable: Bool
}

struct OllamaDeviceStatus: Decodable, Identifiable, Equatable, Hashable {
    var hostId: String
    var displayName: String?
    var installed: Bool
    var reachable: Bool
    var stale: Bool
    var installHint: String

    var id: String { hostId }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }
}

struct OllamaTaskAccepted: Decodable, Equatable {
    var taskID: String
    var hostId: String
}

struct OllamaPullBody: Encodable, Equatable {
    var name: String
    var hostId: String?
}

/// Start/stop JSON is `{ name, hostId? }`. Omit hostId so Home picks already-running, then healthier Device.
struct OllamaModelActionBody: Encodable, Equatable {
    var name: String
    var hostId: String?

    static func start(_ name: String, hostId: String?) -> OllamaModelActionBody {
        OllamaModelActionBody(name: name, hostId: hostId)
    }

    static func stop(_ name: String, hostId: String?) -> OllamaModelActionBody {
        OllamaModelActionBody(name: name, hostId: hostId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        if let hostId, !hostId.isEmpty {
            try container.encode(hostId, forKey: .hostId)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case hostId
    }
}

struct OllamaTaskEvent: Decodable, Equatable {
    var taskID: String
    var kind: String
    var status: String
    var progress: Double?
    var error: String?

    var isTerminal: Bool {
        status == "completed" || status == "failed" || status == "cancelled"
    }

    var percent: Int? {
        guard let progress else { return nil }
        return Int((min(1, max(0, progress)) * 100).rounded())
    }
}

enum OllamaTaskPath {
    static func rest(taskID: String, hostId: String, selfHostId: String?) -> String {
        if let selfHostId, hostId == selfHostId {
            return "/api/tasks/\(taskID)"
        }
        return "/api/home/devices/\(hostId)/v1/tasks/\(taskID)"
    }
}
