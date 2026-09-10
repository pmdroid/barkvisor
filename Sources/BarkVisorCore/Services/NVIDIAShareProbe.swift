import Foundation

enum NVIDIAShareProbe {
    static func live() -> NVIDIAShareFacts {
        #if os(Linux)
            let toolkit = DockerEngine.which("nvidia-ctk") != nil
                || DockerEngine.which("nvidia-container-runtime") != nil
            let gpus = listGPUs()
            let present = !gpus.isEmpty || FileManager.default.fileExists(atPath: "/dev/nvidia0")
            return NVIDIAShareFacts(present: present, toolkitPresent: toolkit, gpus: gpus)
        #else
            return .empty
        #endif
    }

    private static func listGPUs() -> [NVIDIAShareGPU] {
        #if os(Linux)
            guard let smi = DockerEngine.which("nvidia-smi") else { return [] }
            guard let result = try? PlatformProcess.run(
                executable: smi,
                arguments: [
                    "--query-gpu=uuid,name,pci.bus_id",
                    "--format=csv,noheader",
                ],
                timeout: 5,
            ), result.succeeded else { return [] }
            return parseCSV(result.stdoutString)
        #else
            return []
        #endif
    }

    static func parseCSV(_ text: String) -> [NVIDIAShareGPU] {
        var gpus: [NVIDIAShareGPU] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ",", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard parts.count >= 1, !parts[0].isEmpty else { continue }
            let name = parts.count > 1 ? parts[1] : "NVIDIA"
            let pci = parts.count > 2 ? GPUShareService.normalizeNVIDIABusID(parts[2]) : nil
            gpus.append(NVIDIAShareGPU(uuid: parts[0], name: name, pciAddress: pci))
        }
        return gpus
    }
}
