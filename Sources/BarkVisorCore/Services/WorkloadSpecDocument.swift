import Foundation
import Yams

/// Parse + SSA-lite merge for declarative WorkloadSpec documents (PAS-80).
///
/// Merge rule: keys present in the incoming body overwrite; omitted keys stay
/// on the live spec. Nested objects merge; arrays replace wholesale.
public enum WorkloadSpecDocument {
    public static func parse(data: Data, contentType: String?) throws -> [String: Any] {
        let trimmed = data
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest("Request body is required")
        }
        let type = (contentType ?? "").lowercased()
        if isYAML(type) {
            return try parseYAML(trimmed)
        }
        if isJSON(type) {
            return try parseJSON(trimmed)
        }
        if let object = try? parseJSON(trimmed) {
            return object
        }
        return try parseYAML(trimmed)
    }

    public static func decode(_ object: [String: Any]) throws -> WorkloadSpec {
        let normalized = normalizeDefaults(object)
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: normalized)
        } catch {
            throw BarkVisorError.badRequest("Workload document is not a JSON/YAML object")
        }
        do {
            return try WorkloadSpecJSON.decoder.decode(WorkloadSpec.self, from: data)
        } catch {
            throw BarkVisorError.badRequest("Invalid WorkloadSpec: \(error.localizedDescription)")
        }
    }

    public static func jsonObject(from spec: WorkloadSpec) throws -> [String: Any] {
        guard let data = try? WorkloadSpecJSON.encoder.encode(spec),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw BarkVisorError.internalError("Failed to encode WorkloadSpec")
        }
        return object
    }

    /// Deep-merge `overlay` onto `base`. Overlay keys win; omitted keys stay.
    public static func merge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if value is NSNull {
                result[key] = NSNull()
                continue
            }
            if let overlayObject = asStringKeyed(value),
               let baseObject = result[key].flatMap(asStringKeyed) {
                result[key] = merge(base: baseObject, overlay: overlayObject)
            } else {
                result[key] = value
            }
        }
        return result
    }

    public static func merge(base: WorkloadSpec, overlay: [String: Any]) throws -> WorkloadSpec {
        let merged = try merge(base: jsonObject(from: base), overlay: overlay)
        return try decode(merged)
    }

    /// Synthesized WorkloadSpec Codable requires disks/networks/usb arrays.
    /// Apply documents omit them; fill empty arrays so decode matches init defaults.
    private static func normalizeDefaults(_ object: [String: Any]) -> [String: Any] {
        var result = object
        var spec = result["spec"] as? [String: Any] ?? [:]
        if spec["disks"] == nil { spec["disks"] = [] }
        if spec["networks"] == nil { spec["networks"] = [] }
        if spec["usb"] == nil { spec["usb"] = [] }
        if spec["gpu"] == nil { spec["gpu"] = [] }
        result["spec"] = spec
        return result
    }

    // MARK: - Parse helpers

    private static func isYAML(_ type: String) -> Bool {
        type.contains("yaml") || type.contains("yml")
    }

    private static func isJSON(_ type: String) -> Bool {
        type.contains("json")
    }

    private static func parseJSON(_ data: Data) throws -> [String: Any] {
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BarkVisorError.badRequest("Body is not valid JSON")
        }
        guard let object = asStringKeyed(raw) else {
            throw BarkVisorError.badRequest("Workload document must be an object")
        }
        return object
    }

    private static func parseYAML(_ data: Data) throws -> [String: Any] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw BarkVisorError.badRequest("Body is not valid UTF-8")
        }
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: text)
        } catch {
            throw BarkVisorError.badRequest("Body is not valid YAML")
        }
        guard let loaded, let object = asStringKeyed(loaded) else {
            throw BarkVisorError.badRequest("Workload document must be an object")
        }
        return jsonCompatible(object)
    }

    private static func asStringKeyed(_ value: Any) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let dict = value as? [AnyHashable: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, nested) in dict {
            out[String(describing: key)] = nested
        }
        return out
    }

    /// Normalize Yams scalars so JSONSerialization / Codable see JSON types.
    private static func jsonCompatible(_ object: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in object {
            out[key] = jsonCompatibleValue(value)
        }
        return out
    }

    private static func jsonCompatibleValue(_ value: Any) -> Any {
        if value is NSNull { return NSNull() }
        if let object = asStringKeyed(value) {
            return jsonCompatible(object)
        }
        if let array = value as? [Any] {
            return array.map(jsonCompatibleValue)
        }
        if let number = value as? NSNumber {
            return number
        }
        return value
    }
}
