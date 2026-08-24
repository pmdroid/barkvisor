import Foundation
import Yams

public enum CloudInitService {
    /// Validate that user-data is valid YAML when combined with #cloud-config header.
    /// Also rejects keys that would override security-critical directives when appended.
    public static func validateUserData(
        _ userData: String,
        allowCatalogIdentityKeys: Bool = false,
    ) throws {
        let doc = "#cloud-config\n" + userData
        do {
            _ = try Yams.compose(yaml: doc)
        } catch let error as YamlError {
            throw BarkVisorError.badRequest("Invalid cloud-init user-data: \(error)")
        }

        // Wizard extra user-data must not override SSH identity keys.
        // Catalog recipes (Ubuntu, Pi-hole, Onyx) own the full document.
        if allowCatalogIdentityKeys { return }
        let protectedKeys: Set = ["ssh_authorized_keys", "users", "chpasswd", "ssh_pwauth"]
        if let userNode = try? Yams.compose(yaml: "#cloud-config\n" + userData) {
            let mapping = userNode.mapping ?? [:]
            let userKeys = Set(mapping.keys.compactMap(\.string))
            let conflicts = userKeys.intersection(protectedKeys)
            if !conflicts.isEmpty {
                throw BarkVisorError.badRequest(
                    "User-data must not override protected keys: \(conflicts.sorted().joined(separator: ", "))",
                )
            }
        }
    }

    /// Validates SSH key format: must start with a recognized key type prefix
    private static let validSSHKeyPrefixes = [
        "ssh-rsa ", "ssh-ed25519 ", "ssh-dss ", "ecdsa-sha2-nistp256 ",
        "ecdsa-sha2-nistp384 ", "ecdsa-sha2-nistp521 ", "sk-ssh-ed25519@openssh.com ",
        "sk-ecdsa-sha2-nistp256@openssh.com ",
    ]

    public static func validateSSHKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard validSSHKeyPrefixes.contains(where: { trimmed.hasPrefix($0) }) else {
            throw BarkVisorError.badRequest(
                "Invalid SSH key format. Must start with a valid key type (e.g. ssh-rsa, ssh-ed25519)",
            )
        }
        // Reject keys containing newlines or control characters (YAML injection)
        guard !trimmed.contains(where: { $0.isNewline || ($0.asciiValue ?? 32) < 32 }) else {
            throw BarkVisorError.badRequest("SSH key contains invalid characters")
        }
    }

    public static func generateISO(
        vmID: String,
        vmName: String,
        sshKeys: [String],
        userData: String?,
        instanceID: String? = nil,
    ) throws -> URL {
        let dir = generatedISOURL(vmID: vmID).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // meta-data — sanitize vmName for YAML (replace problematic chars)
        let safeName = vmName.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
        let trimmedID = instanceID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedID = trimmedID.isEmpty ? vmID : trimmedID
        let metaData = "instance-id: \(resolvedID)\nlocal-hostname: \(safeName)\n"
        try metaData.write(
            to: dir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8,
        )

        // Validate SSH keys
        for key in sshKeys {
            try validateSSHKey(key)
        }

        // user-data — compose via Yams to avoid fragile string concatenation
        var cloudConfig: [String: Any] = [:]

        if let extra = userData, !extra.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let doc = "#cloud-config\n" + extra
            if let node = try Yams.compose(yaml: doc),
               let mapping = node.mapping {
                for (key, value) in mapping {
                    if let k = key.string {
                        cloudConfig[k] = try Yams.serialize(node: value)
                    }
                }
            }
        }

        if !sshKeys.isEmpty {
            cloudConfig["ssh_authorized_keys"] = sshKeys
        }

        let yamlBody: String
        if cloudConfig.isEmpty {
            yamlBody = ""
        } else {
            // Build a proper Yams Node so serialization is well-formed
            var pairs: [(Yams.Node, Yams.Node)] = []
            for (key, value) in cloudConfig {
                let keyNode = Yams.Node.scalar(.init(key))
                if let arr = value as? [String] {
                    let items = arr.map { Yams.Node.scalar(.init($0)) }
                    pairs.append((keyNode, .sequence(.init(items))))
                } else if let yamlStr = value as? String {
                    // Re-parse the serialized sub-node to preserve structure
                    if let subNode = try Yams.compose(yaml: yamlStr) {
                        pairs.append((keyNode, subNode))
                    }
                }
            }
            let root = Yams.Node.mapping(.init(pairs))
            yamlBody = try Yams.serialize(node: root)
        }

        let ud = "#cloud-config\n" + yamlBody
        try ud.write(to: dir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)

        // Generate ISO using mkisofs / genisoimage (same as Ubuntu's cloud-localds)
        let isoURL = generatedISOURL(vmID: vmID)
        try? FileManager.default.removeItem(at: isoURL)

        let tool = try resolveCloudInitISOTool()
        // genisoimage accepts the same option set as classic mkisofs for this use.
        let result = try PlatformProcess.run(
            executable: tool,
            arguments: [
                "-output", isoURL.path,
                "-volid", "cidata",
                "-joliet", "-rock",
                dir.appendingPathComponent("meta-data").path,
                dir.appendingPathComponent("user-data").path,
            ],
            timeout: 60,
        )

        guard result.succeeded else {
            throw BarkVisorError.cloudInitFailed(
                "cloud-init ISO tool failed: \(result.stderrString)",
            )
        }

        return isoURL
    }

    /// Canonical service-generated cloud-init ISO path for a VM.
    public static func generatedISOURL(vmID: String) -> URL {
        Config.dataDir.appendingPathComponent("cloud-init/\(vmID)/cidata.iso")
    }

    /// user-data written next to the generated ISO, if present.
    public static func storedUserData(vmID: String) -> String? {
        let url = generatedISOURL(vmID: vmID)
            .deletingLastPathComponent()
            .appendingPathComponent("user-data")
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public static func sshAuthorizedKeys(from storedUserData: String?) -> [String] {
        guard let storedUserData, !storedUserData.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let doc = storedUserData.hasPrefix("#cloud-config")
            ? storedUserData
            : "#cloud-config\n" + storedUserData
        guard let node = try? Yams.compose(yaml: doc),
              let seq = node.mapping?["ssh_authorized_keys"]?.sequence
        else { return [] }
        return seq.compactMap(\.string).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Accept the VM's current path (no change) or the service-generated ISO only.
    public static func validateUserDataRef(
        _ ref: String,
        vmID: String,
        current: String? = nil,
    ) throws {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BarkVisorError.badRequest("spec.cloudInit.userDataRef must not be empty")
        }
        if trimmed == current { return }
        let resolved = (trimmed as NSString).resolvingSymlinksInPath
        let expected = (generatedISOURL(vmID: vmID).path as NSString).resolvingSymlinksInPath
        guard resolved == expected else {
            throw BarkVisorError.badRequest(
                "spec.cloudInit.userDataRef must be the service-generated cloud-init ISO for this VM",
            )
        }
    }

    /// Resolve mkisofs-compatible tooling: bundled helper first, then distro PATH.
    /// Linux packages: `genisoimage` (Debian/Ubuntu) or `cdrtools` (mkisofs).
    private static func resolveCloudInitISOTool() throws -> URL {
        if let bundled = try? BundleResolver.helper("mkisofs") {
            return bundled
        }
        // xorriso -as mkisofs is common on EL when genisoimage is absent;
        // we only use pure mkisofs-compatible CLIs here (same flags).
        let names = ["mkisofs", "genisoimage", "xorrisofs"]
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map(String.init)
        let fixed = ["/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
        for name in names {
            for dir in fixed + pathDirs {
                let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        #if os(macOS)
            let hint = "Reinstall BarkVisor (bundled mkisofs) or: brew install cdrtools"
        #else
            let hint = "Install via: apt install genisoimage  |  dnf install genisoimage|xorriso"
        #endif
        throw BarkVisorError.cloudInitFailed(
            "mkisofs/genisoimage not found. \(hint)",
        )
    }
}
