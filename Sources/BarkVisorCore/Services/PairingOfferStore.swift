import Foundation

/// One active pairing offer (hashed secret + display code) at `agent/pairing-offer.json`.
///
/// Independent of SQLite so local VM runtime (PAS-47/90) does not depend
/// on pairing state.
public struct PairingOffer: Codable, Sendable, Equatable {
    public var codeHash: String
    public var codeDisplay: String
    public var createdAt: String
    public var expiresAt: String
    public var consumedAt: String?
    public var agentPort: Int
    /// Address baked into `host=` when the offer was issued. Optional so
    /// legacy `pairing-offer.json` still loads.
    public var advertisedHost: String?

    public init(
        codeHash: String,
        codeDisplay: String,
        createdAt: String,
        expiresAt: String,
        consumedAt: String? = nil,
        agentPort: Int = Config.agentPort,
        advertisedHost: String? = nil,
    ) {
        self.codeHash = codeHash
        self.codeDisplay = codeDisplay
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.consumedAt = consumedAt
        self.agentPort = agentPort
        self.advertisedHost = advertisedHost
    }

    enum CodingKeys: String, CodingKey {
        case codeHash, codeDisplay, createdAt, expiresAt, consumedAt, agentPort, advertisedHost
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.codeHash = try container.decode(String.self, forKey: .codeHash)
        self.codeDisplay = try container.decode(String.self, forKey: .codeDisplay)
        self.createdAt = try container.decode(String.self, forKey: .createdAt)
        self.expiresAt = try container.decode(String.self, forKey: .expiresAt)
        self.consumedAt = try container.decodeIfPresent(String.self, forKey: .consumedAt)
        self.agentPort = try container.decodeIfPresent(Int.self, forKey: .agentPort) ?? Config.agentPort
        self.advertisedHost = try container.decodeIfPresent(String.self, forKey: .advertisedHost)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(codeHash, forKey: .codeHash)
        try container.encode(codeDisplay, forKey: .codeDisplay)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encodeIfPresent(consumedAt, forKey: .consumedAt)
        try container.encode(agentPort, forKey: .agentPort)
        try container.encodeIfPresent(advertisedHost, forKey: .advertisedHost)
    }
}

public final class PairingOfferStore: @unchecked Sendable {
    public static let fileName = "pairing-offer.json"

    public let fileURL: URL
    private let lock = NSLock()

    public init(dataDir: URL) {
        self.fileURL = dataDir
            .appendingPathComponent(HomeCAService.agentDirectoryName)
            .appendingPathComponent(Self.fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> PairingOffer? {
        lock.lock()
        defer { lock.unlock() }
        return try loadLocked()
    }

    public func replace(_ offer: PairingOffer) throws {
        lock.lock()
        defer { lock.unlock() }
        try persistLocked(offer)
    }

    public func clear() throws {
        lock.lock()
        defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Consume the matching unused, unexpired offer. Returns the offer
    /// after marking it consumed, or throws ``PairingError/expiredOrUsed``.
    @discardableResult
    public func consume(code: String, now: Date = Date()) throws -> PairingOffer {
        lock.lock()
        defer { lock.unlock() }
        guard var offer = try loadLocked() else {
            throw PairingError.expiredOrUsed
        }
        if offer.consumedAt != nil {
            throw PairingError.expiredOrUsed
        }
        if let expires = iso8601.date(from: offer.expiresAt), now >= expires {
            throw PairingError.expiredOrUsed
        }
        let incoming = PairingCode.hash(code)
        guard PairingCode.hashesEqual(incoming, offer.codeHash) else {
            throw PairingError.expiredOrUsed
        }
        offer.consumedAt = iso8601.string(from: now)
        try persistLocked(offer)
        return offer
    }

    /// Undo a consume when a later redeem step fails.
    ///
    /// No-op if the file was replaced or is no longer the same consumed offer.
    public func restore(_ offer: PairingOffer) throws {
        lock.lock()
        defer { lock.unlock() }
        guard var current = try loadLocked() else { return }
        guard current.codeHash == offer.codeHash, current.consumedAt != nil else { return }
        current.consumedAt = nil
        try persistLocked(current)
    }

    private func loadLocked() throws -> PairingOffer? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PairingError.unavailable(
                "unable to read pairing-offer.json: \(error.localizedDescription)",
            )
        }
        do {
            return try JSONDecoder().decode(PairingOffer.self, from: data)
        } catch {
            throw PairingError.unavailable(
                "unable to decode pairing-offer.json: \(error.localizedDescription)",
            )
        }
    }

    private func persistLocked(_ offer: PairingOffer) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(offer)
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path,
        )
    }
}
