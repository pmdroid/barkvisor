import CoreTransferable
import Foundation
import UniformTypeIdentifiers

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
    var sizeVRAM: Int64? = nil
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

    /// Running Device for Stop. Nil when the live catalog row is not running.
    var runningHostId: String? {
        guard running else { return nil }
        return locations.first(where: \.running)?.hostId
    }

    static func runningHostId(name: String, in models: [OllamaCatalogModel]) -> String? {
        models.first { $0.name == name }?.runningHostId
    }
}

struct OllamaModelLocation: Decodable, Equatable, Hashable {
    var hostId: String
    var displayName: String?
    var running: Bool
    var reachable: Bool
    var size: Int64? = nil
    var sizeVRAM: Int64? = nil
}

/// Point-in-time `/api/ps` fields already on the Home catalog. Same JSON as web Export JSON.
struct OllamaPsStat: Codable, Equatable {
    var name: String
    var size: Int64?
    var sizeVRAM: Int64?
    var running: Bool
    var host: String

    enum CodingKeys: String, CodingKey {
        case name, size, sizeVRAM, running, host
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(size, forKey: .size)
        try container.encode(sizeVRAM, forKey: .sizeVRAM)
        try container.encode(running, forKey: .running)
        try container.encode(host, forKey: .host)
    }
}

struct OllamaPsExport: Codable, Equatable {
    static let filename = "ollama-ps.json"

    var models: [OllamaPsStat]

    static func serialize(_ models: [OllamaCatalogModel]) -> OllamaPsExport {
        OllamaPsExport(
            models: models.flatMap { model in
                model.locations.map { loc in
                    OllamaPsStat(
                        name: model.name,
                        size: loc.size ?? model.size,
                        sizeVRAM: loc.sizeVRAM ?? (loc.running ? model.sizeVRAM : nil),
                        running: loc.running,
                        host: loc.hostId,
                    )
                }
            },
        )
    }

    func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let text = String(decoding: data, as: UTF8.self)
        if text.hasSuffix("\n") {
            return text
        }
        return text + "\n"
    }

    /// Unique temp file named `ollama-ps.json` for ShareLink / Files.
    func writeJSONFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ollama-ps-\(UUID().uuidString)",
            isDirectory: true,
        )
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Self.filename)
        try Data(jsonString().utf8).write(to: url, options: .atomic)
        return url
    }
}

/// ShareLink payload: JSON file `ollama-ps.json`, encoded only when the user shares.
struct OllamaPsShareFile: Transferable {
    var models: [OllamaCatalogModel]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            SentTransferredFile(try OllamaPsExport.serialize(file.models).writeJSONFile())
        }
        .suggestedFileName(OllamaPsExport.filename)
    }
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

struct OllamaHostSettings: Decodable, Equatable, Identifiable {
    var hostId: String
    var endpoint: String
    var hasApiKey: Bool
    var apiKeyMasked: String?

    var id: String { hostId }
}

struct OllamaSettingsSnapshot: Decodable, Equatable {
    var hosts: [OllamaHostSettings]

    func host(_ hostId: String) -> OllamaHostSettings? {
        hosts.first { $0.hostId == hostId }
    }
}

struct OllamaSettingsUpdate: Encodable, Equatable {
    var hostId: String
    var endpoint: String?
    var apiKey: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hostId, forKey: .hostId)
        if let endpoint, !endpoint.isEmpty {
            try container.encode(endpoint, forKey: .endpoint)
        }
        if let apiKey {
            try container.encode(apiKey, forKey: .apiKey)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case hostId
        case endpoint
        case apiKey
    }
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
