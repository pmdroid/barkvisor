import Foundation

/// Cross-platform path helpers for data dirs, sockets, and install detection.
public enum PlatformPaths {
    /// Application data directory.
    /// - Override: `BARKVISOR_DATA_DIR` (absolute path)
    /// - Installed: `/var/lib/barkvisor` on all platforms
    /// - Dev macOS: `~/Library/Application Support/BarkVisor`
    /// - Dev Linux: `~/.local/share/barkvisor` (or `$XDG_DATA_HOME/barkvisor`)
    public static func dataDir(isInstalled: Bool) -> URL {
        if let override = ProcessInfo.processInfo.environment["BARKVISOR_DATA_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isInstalled {
            return URL(fileURLWithPath: "/var/lib/barkvisor")
        }
        #if os(macOS)
            if let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
            ).first {
                return base.appendingPathComponent("BarkVisor")
            }
            return FileManager.default.temporaryDirectory.appendingPathComponent("BarkVisor")
        #else
            if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
                return URL(fileURLWithPath: xdg).appendingPathComponent("barkvisor")
            }
            if let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty {
                return URL(fileURLWithPath: home)
                    .appendingPathComponent(".local/share/barkvisor")
            }
            return FileManager.default.temporaryDirectory.appendingPathComponent("barkvisor")
        #endif
    }

    /// Short path for unix sockets (must be < 104 bytes on many systems).
    public static func socketDir(isInstalled: Bool) -> URL {
        let base: String
        if isInstalled {
            base = "/var/run/barkvisor"
        } else {
            #if os(macOS)
                base = NSTemporaryDirectory() + "barkvisor"
            #else
                let tmp = ProcessInfo.processInfo.environment["TMPDIR"]
                    ?? ProcessInfo.processInfo.environment["TMP"]
                    ?? "/tmp"
                base = (tmp as NSString).appendingPathComponent("barkvisor")
            #endif
        }
        let dir = URL(fileURLWithPath: base)
        try? FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700],
        )
        return dir
    }

    /// True when a host-arch QEMU binary is present under libexec.
    public static func isInstalled(libexecDir: String) -> Bool {
        let fm = FileManager.default
        let candidates = [
            "\(libexecDir)/qemu-system-aarch64",
            "\(libexecDir)/qemu-system-x86_64",
        ]
        return candidates.contains { fm.isExecutableFile(atPath: $0) }
    }

    // MARK: - Settings (UserDefaults on macOS, JSON on Linux)

    private static let settingsFileName = "settings.json"

    /// Read a settings value. macOS uses UserDefaults; Linux uses `dataDir/settings.json`.
    public static func settingsValue(forKey key: String, dataDir: URL) -> Any? {
        #if os(macOS)
            return UserDefaults.standard.object(forKey: key)
        #else
            return loadSettings(dataDir: dataDir)[key]
        #endif
    }

    public static func settingsBool(forKey key: String, dataDir: URL, default defaultValue: Bool) -> Bool {
        #if os(macOS)
            if UserDefaults.standard.object(forKey: key) == nil { return defaultValue }
            return UserDefaults.standard.bool(forKey: key)
        #else
            if let value = loadSettings(dataDir: dataDir)[key] as? Bool {
                return value
            }
            return defaultValue
        #endif
    }

    public static func settingsInt(forKey key: String, dataDir: URL, default defaultValue: Int) -> Int {
        #if os(macOS)
            let val = UserDefaults.standard.integer(forKey: key)
            return val > 0 ? val : defaultValue
        #else
            if let value = loadSettings(dataDir: dataDir)[key] as? Int, value > 0 {
                return value
            }
            if let value = loadSettings(dataDir: dataDir)[key] as? NSNumber {
                let intVal = value.intValue
                return intVal > 0 ? intVal : defaultValue
            }
            return defaultValue
        #endif
    }

    public static func settingsString(forKey key: String, dataDir: URL) -> String? {
        #if os(macOS)
            return UserDefaults.standard.string(forKey: key)
        #else
            return loadSettings(dataDir: dataDir)[key] as? String
        #endif
    }

    /// Persist a settings value (used by callers that need Linux JSON + macOS UserDefaults).
    public static func setSettingsValue(_ value: Any?, forKey key: String, dataDir: URL) {
        #if os(macOS)
            UserDefaults.standard.set(value, forKey: key)
        #else
            var dict = loadSettings(dataDir: dataDir)
            if let value {
                dict[key] = value
            } else {
                dict.removeValue(forKey: key)
            }
            saveSettings(dict, dataDir: dataDir)
        #endif
    }

    #if !os(macOS)
        private static func settingsURL(dataDir: URL) -> URL {
            dataDir.appendingPathComponent(settingsFileName)
        }

        private static func loadSettings(dataDir: URL) -> [String: Any] {
            let url = settingsURL(dataDir: dataDir)
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any]
            else {
                return [:]
            }
            return dict
        }

        private static func saveSettings(_ dict: [String: Any], dataDir: URL) {
            try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
            guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
            else { return }
            try? data.write(to: settingsURL(dataDir: dataDir), options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL(dataDir: dataDir).path,
            )
        }
    #endif
}
