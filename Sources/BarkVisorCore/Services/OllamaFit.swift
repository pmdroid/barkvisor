import Foundation

/// Load-time RAM fit check before `ollama run` / generate keep_alive (PAS-269).
public enum OllamaFit {
    /// Extra headroom on top of the on-disk model size.
    public static let overheadFraction = 0.10

    public static func check(
        modelBytes: Int64?,
        memoryTotalMB: Int?,
        memoryUsedMB: Int?,
    ) -> OllamaFitResult {
        guard let modelBytes, modelBytes > 0 else {
            return OllamaFitResult(ok: true)
        }
        guard let total = memoryTotalMB, let used = memoryUsedMB, total > 0 else {
            return OllamaFitResult(
                ok: false,
                reason: "this Device did not report memory, so Ollama cannot load the model yet.",
            )
        }
        let freeBytes = Int64(max(0, total - used)) * 1_024 * 1_024
        let needed = Int64((Double(modelBytes) * (1 + overheadFraction)).rounded(.up))
        if freeBytes >= needed {
            return OllamaFitResult(ok: true)
        }
        let needMB = max(1, needed / (1_024 * 1_024))
        let freeMB = max(0, total - used)
        return OllamaFitResult(
            ok: false,
            reason:
            "Ollama needs about \(needMB) MB free to load this model; this Device has \(freeMB) MB free.",
        )
    }
}
