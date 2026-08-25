import Foundation

public enum OllamaLibrarySearch {
    public static let upstreamHost = "ollama.com"
    public static let allowedHosts: Set<String> = [upstreamHost]
    public static let upstreamURLString = "https://ollama.com/api/tags"
    public static var upstreamURL: URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = upstreamHost
        parts.path = "/api/tags"
        return parts.url ?? URL(fileURLWithPath: "/api/tags")
    }

    public struct Model: Equatable, Sendable {
        public var name: String
        public var description: String?
        public var size: Int64?

        public init(name: String, description: String? = nil, size: Int64? = nil) {
            self.name = name
            self.description = description
            self.size = size
        }
    }

    public struct Result: Codable, Equatable, Sendable {
        public var name: String
        public var description: String?
        public var size: Int64?

        public init(name: String, description: String? = nil, size: Int64? = nil) {
            self.name = name
            self.description = description
            self.size = size
        }
    }

    public struct Response: Codable, Equatable, Sendable {
        public var query: String
        public var upstream: String
        public var results: [Result]

        public init(
            query: String,
            upstream: String = OllamaLibrarySearch.upstreamURLString,
            results: [Result],
        ) {
            self.query = query
            self.upstream = upstream
            self.results = results
        }
    }

    public static func map(query: String, models: [Model]) -> [Result] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return [] }
        var seen: Set<String> = []
        var results: [Result] = []
        for model in models {
            let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { continue }
            let key = name.lowercased()
            if seen.contains(key) { continue }
            let description = model.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let haystack = "\(name) \(description)".lowercased()
            guard haystack.contains(q) else { continue }
            seen.insert(key)
            results.append(
                Result(
                    name: name,
                    description: description.isEmpty ? nil : description,
                    size: model.size,
                ),
            )
        }
        return results
    }

    public static func models(from data: Data) throws -> [Model] {
        let decoded = try JSONDecoder().decode(TagsBody.self, from: data)
        return (decoded.models ?? []).compactMap { tag in
            let name = (tag.name ?? tag.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            let description = tag.description?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Model(
                name: name,
                description: description?.isEmpty == false ? description : nil,
                size: tag.size,
            )
        }
    }

    private struct TagsBody: Decodable {
        var models: [Tag]?

        struct Tag: Decodable {
            var name: String?
            var model: String?
            var description: String?
            var size: Int64?
        }
    }
}
