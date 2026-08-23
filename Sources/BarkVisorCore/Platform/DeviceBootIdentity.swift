import Foundation

#if os(macOS)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// Identity of this Device boot. Daemon restart on the same boot keeps the same id.
public enum DeviceBootIdentity {
    /// Linux `boot_id`, macOS `kern.boottime`. Nil means autostart must not run.
    public static func current() -> String? {
        #if os(macOS)
            var boot = timeval()
            var size = MemoryLayout<timeval>.size
            guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
            return "kern.boottime:\(boot.tv_sec).\(boot.tv_usec)"
        #else
            let raw = try? String(contentsOfFile: "/proc/sys/kernel/random/boot_id", encoding: .utf8)
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        #endif
    }
}
