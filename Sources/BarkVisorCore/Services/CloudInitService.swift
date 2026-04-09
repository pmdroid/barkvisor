import Foundation
import Yams

public enum CloudInitService {
    /// Validate that user-data is valid YAML when combined with #cloud-config header.
    /// Also rejects keys that would override security-critical directives when appended.
    public static func validateUserData(_ userData: String) throws {
        let doc = "#cloud-config\n" + userData
        do {
            _ = try Yams.compose(yaml: doc)
        } catch let error as YamlError {
            throw BarkVisorError.badRequest("Invalid cloud-init user-data: \(error)")
        }

        // Parse just the user-provided portion and reject protected keys
        // that could override security-critical directives via YAML duplicate-key semantics
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

    /// Read current user-data for a VM (strips #cloud-config header)
    public static func readUserData(vmID: String) -> String? {
        let path = Config.dataDir.appendingPathComponent("cloud-init/\(vmID)/user-data")
        guard let content = try? String(contentsOf: path, encoding: .utf8) else { return nil }
        // Strip the #cloud-config header line
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first == "#cloud-config" {
            return lines.dropFirst().joined(separator: "\n")
        }
        return content
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

    public static func generateISO(vmID: String, vmName: String, sshKeys: [String], userData: String?)
        throws -> URL {
        let dir = Config.dataDir.appendingPathComponent("cloud-init/\(vmID)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // meta-data — sanitize vmName for YAML (replace problematic chars)
        let safeName = vmName.filter {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "."
        }
        let metaData = "instance-id: \(vmID)\nlocal-hostname: \(safeName)\n"
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

        // Generate ISO using mkisofs (same as Ubuntu's cloud-localds)
        let isoURL = dir.appendingPathComponent("cidata.iso")
        try? FileManager.default.removeItem(at: isoURL)

        let tool: URL
        if let mkisofs = try? BundleResolver.helper("mkisofs") {
            tool = mkisofs
        } else {
            throw BarkVisorError.cloudInitFailed(
                "mkisofs not found — it should be bundled inside the app",
            )
        }

        let process = Process()
        process.executableURL = tool
        process.arguments = [
            "-output", isoURL.path,
            "-volid", "cidata",
            "-joliet", "-rock",
            dir.appendingPathComponent("meta-data").path,
            dir.appendingPathComponent("user-data").path,
        ]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr =
                String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BarkVisorError.cloudInitFailed("mkisofs failed: \(stderr)")
        }

        return isoURL
    }
}
