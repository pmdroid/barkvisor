import Foundation

public enum UnslothStagedModels {
    public static func directory(dataDir: URL) -> URL {
        dataDir
            .appendingPathComponent("unsloth", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    public struct Entry: Sendable {
        public var name: String
        public var path: URL
        public var size: Int64?

        public init(name: String, path: URL, size: Int64?) {
            self.name = name
            self.path = path
            self.size = size
        }
    }

    public static func entries(in modelsDir: URL) throws -> [Entry] {
        let items = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
        )
        return (items ?? [])
            .map { Entry(name: $0.lastPathComponent, path: $0, size: fileSize(at: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func models(in modelsDir: URL, running: String?) throws -> [OllamaLocalModel] {
        let servingKey = running.map { OllamaModelName.canonical($0) }
        return try entries(in: modelsDir).map { entry in
            OllamaLocalModel(
                name: entry.name,
                size: entry.size,
                running: servingKey == OllamaModelName.canonical(entry.name),
            )
        }
    }

    private static func fileSize(at item: URL) -> Int64? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: item.path, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue {
            guard let enumerator = fm.enumerator(
                at: item,
                includingPropertiesForKeys: [.fileSizeKey],
            ) else {
                return nil
            }
            var total: Int64 = 0
            for case let file as URL in enumerator {
                if let bytes = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                    total += Int64(bytes)
                }
            }
            return total
        }
        guard let attrs = try? fm.attributesOfItem(atPath: item.path),
              let bytes = (attrs[.size] as? NSNumber)?.int64Value else {
            return nil
        }
        return bytes
    }
}
