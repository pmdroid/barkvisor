import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public enum PlatformProcess {
    /// Best-effort absolute path for a process executable, or nil.
    public static func executablePath(pid: Int32) -> String? {
        #if os(macOS)
            var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let ret = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard ret > 0 else { return nil }
            return String(cString: pathBuffer)
        #else
            let link = "/proc/\(pid)/exe"
            var buf = [CChar](repeating: 0, count: 4_096)
            let n = readlink(link, &buf, buf.count - 1)
            guard n > 0 else { return nil }
            return String(cString: buf)
        #endif
    }
}
