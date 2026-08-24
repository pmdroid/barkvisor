import Foundation

/// Kind of BarkVisor API token (PAS-269). Full keys keep today's :7777 surface.
/// Inference tokens may list/run completions only.
public enum APIKeyKind: String, Codable, Sendable, CaseIterable {
    case full
    case inference

    /// Unknown stored values fail closed as inference, not full admin.
    public static func parseStored(_ raw: String?) -> APIKeyKind {
        guard let raw, let kind = APIKeyKind(rawValue: raw) else { return .inference }
        return kind
    }
}

/// Host Ollama detect + HTTP snapshot (PAS-269). Not a model runner.
public struct OllamaDetectResult: Codable, Sendable, Equatable {
    public var installed: Bool
    public var binaryPath: String?
    public var installHint: String

    public init(installed: Bool, binaryPath: String?, installHint: String) {
        self.installed = installed
        self.binaryPath = binaryPath
        self.installHint = installHint
    }
}

public struct OllamaLocalModel: Codable, Sendable, Equatable {
    public var name: String
    public var digest: String?
    public var size: Int64?
    public var running: Bool
    public var parameterSize: String?
    public var quantization: String?

    public init(
        name: String,
        digest: String? = nil,
        size: Int64? = nil,
        running: Bool,
        parameterSize: String? = nil,
        quantization: String? = nil,
    ) {
        self.name = name
        self.digest = digest
        self.size = size
        self.running = running
        self.parameterSize = parameterSize
        self.quantization = quantization
    }
}

public struct OllamaTagRecord: Sendable, Equatable {
    public var name: String
    public var digest: String?
    public var size: Int64?
    public var parameterSize: String?
    public var quantization: String?

    public init(
        name: String,
        digest: String? = nil,
        size: Int64? = nil,
        parameterSize: String? = nil,
        quantization: String? = nil,
    ) {
        self.name = name
        self.digest = digest
        self.size = size
        self.parameterSize = parameterSize
        self.quantization = quantization
    }
}

public struct OllamaRunningRecord: Sendable, Equatable {
    public var name: String
    public var digest: String?
    public var size: Int64?
    public var sizeVRAM: Int64?

    public init(name: String, digest: String? = nil, size: Int64? = nil, sizeVRAM: Int64? = nil) {
        self.name = name
        self.digest = digest
        self.size = size
        self.sizeVRAM = sizeVRAM
    }
}

public struct OllamaDeviceSnapshot: Codable, Sendable, Equatable {
    public var hostId: String
    public var displayName: String?
    public var installed: Bool
    public var reachable: Bool
    public var binaryPath: String?
    public var installHint: String
    public var probedAt: String
    public var models: [OllamaLocalModel]
    public var memoryTotalMB: Int?
    public var memoryUsedMB: Int?
    public var cpuLoadPercent: Double?

    public init(
        hostId: String,
        displayName: String? = nil,
        installed: Bool,
        reachable: Bool,
        binaryPath: String? = nil,
        installHint: String,
        probedAt: String,
        models: [OllamaLocalModel] = [],
        memoryTotalMB: Int? = nil,
        memoryUsedMB: Int? = nil,
        cpuLoadPercent: Double? = nil,
    ) {
        self.hostId = hostId
        self.displayName = displayName
        self.installed = installed
        self.reachable = reachable
        self.binaryPath = binaryPath
        self.installHint = installHint
        self.probedAt = probedAt
        self.models = models
        self.memoryTotalMB = memoryTotalMB
        self.memoryUsedMB = memoryUsedMB
        self.cpuLoadPercent = cpuLoadPercent
    }
}

public struct OllamaModelLocation: Codable, Sendable, Equatable {
    public var hostId: String
    public var displayName: String?
    public var running: Bool
    public var reachable: Bool
    public var probedAt: String
    public var size: Int64?
    public var digest: String?
    public var memoryTotalMB: Int?
    public var memoryUsedMB: Int?
    public var cpuLoadPercent: Double?

    public init(
        hostId: String,
        displayName: String? = nil,
        running: Bool,
        reachable: Bool,
        probedAt: String,
        size: Int64? = nil,
        digest: String? = nil,
        memoryTotalMB: Int? = nil,
        memoryUsedMB: Int? = nil,
        cpuLoadPercent: Double? = nil,
    ) {
        self.hostId = hostId
        self.displayName = displayName
        self.running = running
        self.reachable = reachable
        self.probedAt = probedAt
        self.size = size
        self.digest = digest
        self.memoryTotalMB = memoryTotalMB
        self.memoryUsedMB = memoryUsedMB
        self.cpuLoadPercent = cpuLoadPercent
    }

    public var freeMemoryMB: Int? {
        guard let total = memoryTotalMB, let used = memoryUsedMB else { return nil }
        return max(0, total - used)
    }
}

public struct OllamaCatalogModel: Codable, Sendable, Equatable {
    public var name: String
    public var digest: String?
    public var size: Int64?
    public var running: Bool
    public var locations: [OllamaModelLocation]

    public init(
        name: String,
        digest: String? = nil,
        size: Int64? = nil,
        running: Bool,
        locations: [OllamaModelLocation],
    ) {
        self.name = name
        self.digest = digest
        self.size = size
        self.running = running
        self.locations = locations
    }
}

public struct OllamaHomeCatalog: Codable, Sendable, Equatable {
    public var anyReachable: Bool
    public var anyInstalled: Bool
    public var refreshedAt: String?
    public var models: [OllamaCatalogModel]
    public var devices: [OllamaDeviceStatus]

    public init(
        anyReachable: Bool,
        anyInstalled: Bool,
        refreshedAt: String? = nil,
        models: [OllamaCatalogModel] = [],
        devices: [OllamaDeviceStatus] = [],
    ) {
        self.anyReachable = anyReachable
        self.anyInstalled = anyInstalled
        self.refreshedAt = refreshedAt
        self.models = models
        self.devices = devices
    }
}

public struct OllamaDeviceStatus: Codable, Sendable, Equatable {
    public var hostId: String
    public var displayName: String?
    public var installed: Bool
    public var reachable: Bool
    public var stale: Bool
    public var binaryPath: String?
    public var installHint: String
    public var probedAt: String?

    public init(
        hostId: String,
        displayName: String? = nil,
        installed: Bool,
        reachable: Bool,
        stale: Bool,
        binaryPath: String? = nil,
        installHint: String,
        probedAt: String? = nil,
    ) {
        self.hostId = hostId
        self.displayName = displayName
        self.installed = installed
        self.reachable = reachable
        self.stale = stale
        self.binaryPath = binaryPath
        self.installHint = installHint
        self.probedAt = probedAt
    }
}

public struct OllamaPersistedMap: Codable, Sendable, Equatable {
    public var refreshedAt: String?
    public var devices: [OllamaDeviceSnapshot]

    public init(refreshedAt: String? = nil, devices: [OllamaDeviceSnapshot] = []) {
        self.refreshedAt = refreshedAt
        self.devices = devices
    }
}

public struct OllamaFitResult: Sendable, Equatable {
    public var ok: Bool
    public var reason: String?

    public init(ok: Bool, reason: String? = nil) {
        self.ok = ok
        self.reason = reason
    }
}

public struct OllamaHostSettings: Codable, Sendable, Equatable {
    public var hostId: String
    public var endpoint: String
    public var hasApiKey: Bool
    public var apiKeyMasked: String?

    public init(hostId: String, endpoint: String, hasApiKey: Bool, apiKeyMasked: String? = nil) {
        self.hostId = hostId
        self.endpoint = endpoint
        self.hasApiKey = hasApiKey
        self.apiKeyMasked = apiKeyMasked
    }
}

/// Masked Home settings. `apiKey` is never present on read.
public struct OllamaSettingsSnapshot: Codable, Sendable, Equatable {
    public var hosts: [OllamaHostSettings]

    public init(hosts: [OllamaHostSettings] = []) {
        self.hosts = hosts
    }

    public func host(_ hostId: String) -> OllamaHostSettings? {
        hosts.first { $0.hostId == hostId }
    }
}

/// PUT body `{ hostId, endpoint?, apiKey? }`. Omit `apiKey` to leave the stored key; send `""` to clear.
public struct OllamaSettingsUpdate: Codable, Sendable, Equatable {
    public var hostId: String
    public var endpoint: String?
    public var apiKey: String?

    public init(hostId: String, endpoint: String? = nil, apiKey: String? = nil) {
        self.hostId = hostId
        self.endpoint = endpoint
        self.apiKey = apiKey
    }
}

public struct OllamaPullEvent: Codable, Sendable, Equatable {
    public var status: String?
    public var digest: String?
    public var total: Int64?
    public var completed: Int64?
    public var error: String?

    public init(
        status: String? = nil,
        digest: String? = nil,
        total: Int64? = nil,
        completed: Int64? = nil,
        error: String? = nil,
    ) {
        self.status = status
        self.digest = digest
        self.total = total
        self.completed = completed
        self.error = error
    }

    public var fraction: Double? {
        guard let total, total > 0, let completed else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
}

public struct OllamaNativeTags: Codable, Sendable, Equatable {
    public var models: [OllamaNativeTag]

    public init(models: [OllamaNativeTag]) {
        self.models = models
    }
}

public struct OllamaNativeTag: Codable, Sendable, Equatable {
    public var name: String
    public var model: String?
    public var size: Int64?
    public var digest: String?

    public init(name: String, model: String? = nil, size: Int64? = nil, digest: String? = nil) {
        self.name = name
        self.model = model
        self.size = size
        self.digest = digest
    }
}

public struct OllamaNativePS: Codable, Sendable, Equatable {
    public var models: [OllamaNativePSModel]

    public init(models: [OllamaNativePSModel]) {
        self.models = models
    }
}

public struct OllamaNativePSModel: Codable, Sendable, Equatable {
    public var name: String
    public var model: String?
    public var size: Int64?
    public var digest: String?
    public var sizeVRAM: Int64?

    public init(
        name: String,
        model: String? = nil,
        size: Int64? = nil,
        digest: String? = nil,
        sizeVRAM: Int64? = nil,
    ) {
        self.name = name
        self.model = model
        self.size = size
        self.digest = digest
        self.sizeVRAM = sizeVRAM
    }

    enum CodingKeys: String, CodingKey {
        case name, model, size, digest
        case sizeVRAM = "size_vram"
    }
}
