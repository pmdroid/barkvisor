import Foundation
import Yams

public enum DockerServiceHealth {
    public static func roles(composeYaml: String?) -> [String: String] {
        guard let composeYaml, let loaded = try? Yams.load(yaml: composeYaml) as? [String: Any] else {
            return [:]
        }
        guard let services = loaded["services"] as? [String: Any] else { return [:] }
        var roles: [String: String] = [:]
        for (name, raw) in services {
            let service = raw as? [String: Any] ?? [:]
            let restart = (service["restart"] as? String)?.lowercased()
            roles[name] = restart == "no"
                ? WorkloadServiceObservation.roleOneShot
                : WorkloadServiceObservation.roleLongRunning
        }
        return roles
    }

    public static func containerNames(workloadID: String, composeYaml: String?) -> [String] {
        roles(composeYaml: composeYaml).keys.sorted().map {
            ComposeAllowlist.containerName(workloadID: workloadID, service: $0)
        }
    }

    public static func observations(inspectJSON: Data, roles: [String: String]) -> [WorkloadServiceObservation] {
        guard let root = try? JSONSerialization.jsonObject(with: inspectJSON) else { return [] }
        let containers = root as? [Any] ?? [root]
        var found: [WorkloadServiceObservation] = []
        for raw in containers {
            guard let object = raw as? [String: Any] else { continue }
            let labels = ((object["Config"] as? [String: Any])?["Labels"] as? [String: Any]) ?? [:]
            let service = (labels["com.docker.compose.service"] as? String)
                ?? serviceName(container: object["Name"] as? String)
            guard let service else { continue }
            let state = object["State"] as? [String: Any] ?? [:]
            let status = (state["Status"] as? String)?.lowercased() ?? ""
            let runningFlag = state["Running"] as? Bool
            let running = runningFlag == true || status == "running"
            let exitCode = intValue(state["ExitCode"])
            let healthObject = state["Health"] as? [String: Any]
            let health = (healthObject?["Status"] as? String)?.lowercased() ?? "none"
            let role = roles[service] ?? WorkloadServiceObservation.roleLongRunning
            found.append(
                WorkloadServiceObservation(
                    name: service,
                    role: role,
                    running: running,
                    exitCode: exitCode,
                    health: health,
                    required: true,
                ),
            )
        }
        return found.sorted { $0.name < $1.name }
    }

    public static func enforcedResources(inspectJSON: Data) -> (cpu: Int?, memoryMb: Int?) {
        guard let root = try? JSONSerialization.jsonObject(with: inspectJSON) else { return (nil, nil) }
        let containers = root as? [Any] ?? [root]
        var cpus: [Int] = []
        var memories: [Int] = []
        for raw in containers {
            guard let object = raw as? [String: Any] else { continue }
            let host = object["HostConfig"] as? [String: Any] ?? [:]
            if let nano = intValue(host["NanoCpus"]), nano > 0 {
                cpus.append(max(1, nano / 1_000_000_000))
            }
            if let bytes = intValue(host["Memory"]), bytes > 0 {
                memories.append(max(1, bytes / (1_024 * 1_024)))
            }
        }
        let cpu = Set(cpus).count == 1 ? cpus[0] : nil
        let memory = Set(memories).count == 1 ? memories[0] : nil
        return (cpu, memory)
    }

    private static func serviceName(container: String?) -> String? {
        guard let container else { return nil }
        let trimmed = container.hasPrefix("/") ? String(container.dropFirst()) : container
        guard let range = trimmed.range(of: "bv-") else { return nil }
        let rest = trimmed[range.upperBound...]
        guard let split = rest.lastIndex(of: "-") else { return nil }
        let name = rest[rest.index(after: split)...]
        return name.isEmpty ? nil : String(name)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        if let number = value as? Int64 { return Int(number) }
        if let number = value as? Double { return Int(number) }
        if let number = value as? NSNumber { return number.intValue }
        return nil
    }
}
