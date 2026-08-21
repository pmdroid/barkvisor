import Foundation

/// Chardev backends this Device's QEMU actually compiled in.
///
/// `qemu-vdagent` needs SPICE in the QEMU build. Homebrew often has it; the
/// BarkVisor-packaged `qemu-system-*` (10.2) does not. Passing
/// `-chardev qemu-vdagent,...` then exits 1 and the Workload goes Error.
public enum QEMUChardev {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: Bool] = [:]

    /// `-chardev help` lists backends without instantiating a machine.
    /// `-machine virt` is ARM-only and fails on qemu-system-x86_64.
    static let vdagentProbeArguments = ["-chardev", "help"]

    public static func supportsVdagent(binary: URL) -> Bool {
        let key = binaryIdentityKey(for: binary)
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let ok = probeVdagent(binary: binary)
        lock.lock()
        cache[key] = ok
        lock.unlock()
        return ok
    }

    /// Unit tests inject captured `-chardev help` text.
    public static func helpListsVdagent(_ text: String) -> Bool {
        text.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces) == "qemu-vdagent"
        }
    }

    /// Path plus mtime and size so an in-place QEMU upgrade re-probes.
    static func binaryIdentityKey(for binary: URL) -> String {
        let path = binary.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        return "\(path)|\(mtime)|\(size)"
    }

    private static func probeVdagent(binary: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return false }
        let result = try? PlatformProcess.run(
            executable: binary,
            arguments: vdagentProbeArguments,
            timeout: 8,
        )
        let text = (result?.stdoutString ?? "") + "\n" + (result?.stderrString ?? "")
        return helpListsVdagent(text)
    }
}
