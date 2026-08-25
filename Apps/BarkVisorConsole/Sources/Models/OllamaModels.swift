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

    var id: String {
        name
    }

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

    /// Devices that already have this model's weights. Start can only run here.
    var startLocations: [OllamaModelLocation] {
        locations
    }

    /// hostId when exactly one Device has the model.
    var soleStartHostId: String? {
        guard startLocations.count == 1 else { return nil }
        return startLocations[0].hostId
    }

    /// True when Start must pick among multiple Devices that have the model.
    var startNeedsPicker: Bool {
        startLocations.count > 1
    }
}

struct OllamaModelLocation: Decodable, Equatable, Hashable {
    var hostId: String
    var displayName: String?
    var running: Bool
    var reachable: Bool
    var size: Int64? = nil
    var sizeVRAM: Int64? = nil

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }
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
            try SentTransferredFile(OllamaPsExport.serialize(file.models).writeJSONFile())
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

    var id: String {
        hostId
    }

    var title: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? hostId : name
    }
}

enum OllamaDeviceStats {
    static let gpuEmptyCopy = "This Device has no GPU."

    static var unreachableCopy: String {
        "This \(Copy.device.lowercased()) did not answer. CPU, memory, and GPU are unknown."
    }

    static func defaultHostId(models: [OllamaCatalogModel], devices: [OllamaDeviceStatus]) -> String {
        let locations = models.flatMap(\.locations)
        if let row = locations.first(where: { $0.running && $0.reachable }) {
            return row.hostId
        }
        if let row = locations.first(where: \.running) {
            return row.hostId
        }
        return devices.first(where: \.reachable)?.hostId ?? devices.first?.hostId ?? ""
    }

    static func shouldFetch(catalogDevice: OllamaDeviceStatus?, health: HomeDeviceHealthSnapshot?) -> Bool {
        guard let catalogDevice, catalogDevice.reachable else { return false }
        if let health { return DeviceStatsHistory.shouldFetch(health) }
        return true
    }

    static func healthTarget(
        hostId: String,
        catalog: [OllamaDeviceStatus],
        devices: [HomeDeviceHealthSnapshot],
    ) -> HomeDeviceHealthSnapshot? {
        if hostId.isEmpty { return nil }
        if let row = devices.first(where: { $0.hostId == hostId }) { return row }
        guard let catalogDevice = catalog.first(where: { $0.hostId == hostId }) else { return nil }
        let isSelf = devices.contains { $0.isSelf && $0.hostId == hostId }
        return HomeDeviceHealthSnapshot(
            hostId: hostId,
            role: isSelf ? "self" : "member",
            displayName: catalogDevice.displayName,
            fingerprint: nil,
            agentHost: nil,
            agentPort: DeviceURL.defaultPort,
            pairedAt: nil,
            reachability: catalogDevice.reachable ? "ok" : "unreachable",
            reachabilityError: catalogDevice.reachable ? nil : "Device is unreachable",
            collectedAt: nil,
            platform: nil,
            resources: nil,
            workloadCount: nil,
            healthCounts: nil,
        )
    }

    static func occupancyLines(_ gpu: HostGPUDevice) -> [String] {
        var lines = [gpu.name]
        if let driver = gpu.driver, !driver.isEmpty { lines.append(driver) }
        if gpu.vfioBound == true { lines.append("vfio-pci") }
        if let occupancy = gpu.occupancyCopy { lines.append(occupancy) }
        lines.append(
            "Group mates: \(GPUPassthroughCopy.groupMatesLabel(pciAddress: gpu.pciAddress, groupAddresses: gpu.groupAddresses))",
        )
        return lines
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

    var id: String {
        hostId
    }
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

    /// PUT body for a new key. Nil when host or draft is blank so JSON omits
    /// `apiKey`. A present empty string would clear the stored key.
    static func saveKey(hostId: String, draft: String) -> OllamaSettingsUpdate? {
        let hostId = hostId.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hostId.isEmpty, !apiKey.isEmpty else { return nil }
        return OllamaSettingsUpdate(hostId: hostId, apiKey: apiKey)
    }

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
