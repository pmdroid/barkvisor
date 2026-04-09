import CryptoKit
import Foundation

public enum TemplateRenderer {
    public static func render(template: String, inputs: [String: String]) throws -> String {
        guard !template.isEmpty else { return "" }

        var result = template

        // Compute password_hash from raw password
        if let password = inputs["password"] {
            let hash = generateSHA512Crypt(password: password)
            result = result.replacingOccurrences(of: "{{password_hash}}", with: hash)
        }

        // Compute ssh_keys_yaml from ssh_keys
        if let sshKeys = inputs["ssh_keys"], !sshKeys.isEmpty {
            let lines = sshKeys.split(separator: "\n")
                .map(String.init)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "      - \($0)" }
                .joined(separator: "\n")
            result = result.replacingOccurrences(of: "{{ssh_keys_yaml}}", with: lines)
        } else {
            result = result.replacingOccurrences(of: "{{ssh_keys_yaml}}", with: "")
        }

        // Compute extra_packages_yaml from extra_packages
        if let packages = inputs["extra_packages"], !packages.isEmpty {
            let lines = packages.split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
                .map { "  - \($0)" }
                .joined(separator: "\n")
            result = result.replacingOccurrences(of: "{{extra_packages_yaml}}", with: lines)
        } else {
            result = result.replacingOccurrences(of: "{{extra_packages_yaml}}", with: "")
        }

        // Replace all simple {{key}} placeholders with YAML-escaped values
        // Skip keys that were already handled as special variables above
        let processedKeys: Set = ["password", "ssh_keys", "extra_packages"]
        for (key, value) in inputs where !processedKeys.contains(key) {
            result = result.replacingOccurrences(of: "{{\(key)}}", with: escapeYAMLValue(value))
        }

        return result
    }

    /// Escape a string for safe insertion into a YAML value position.
    /// Wraps in single quotes and escapes embedded single quotes ('' in YAML).
    private static func escapeYAMLValue(_ value: String) -> String {
        // If the value contains characters that could break YAML structure, quote it
        let dangerousChars: Set<Character> = [
            "\n",
            "\r",
            ":",
            "#",
            "{",
            "}",
            "[",
            "]",
            ",",
            "&",
            "*",
            "?",
            "|",
            "-",
            "<",
            ">",
            "=",
            "!",
            "%",
            "@",
            "`",
            "\"",
            "'",
        ]
        let needsQuoting = value.contains(where: { dangerousChars.contains($0) })
        if needsQuoting {
            // YAML single-quoted strings: only escape mechanism is '' for a literal '
            let escaped = value.replacingOccurrences(of: "'", with: "''")
            return "'\(escaped)'"
        }
        return value
    }

    // MARK: - SHA-512 Crypt ($6$) — pure Swift implementation

    private static let itoa64 = Array(
        "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8,
    )

    public static func generateSHA512Crypt(password: String, rounds: Int = 5_000) -> String {
        // Generate 16-byte random salt
        var saltBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes)
        let salt = saltBytes.map { itoa64[Int($0) % itoa64.count] }.map { Character(UnicodeScalar($0)) }
        let saltString = String(salt)

        return sha512Crypt(password: password, salt: saltString, rounds: rounds)
    }

    public static func sha512Crypt(password: String, salt: String, rounds: Int = 5_000) -> String {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.prefix(16).utf8)

        // Step 1-3: Digest B = SHA512(password + salt + password)
        let digestB = sha512(passwordBytes + saltBytes + passwordBytes)

        // Step 4-8: Digest A = SHA512(password + salt + digestB-derived)
        var digestAInput = passwordBytes + saltBytes
        var remaining = passwordBytes.count
        while remaining > 64 {
            digestAInput += digestB
            remaining -= 64
        }
        digestAInput += Array(digestB.prefix(remaining))

        // Step 9: bit-toggling based on password length
        var length = passwordBytes.count
        while length > 0 {
            if length & 1 != 0 {
                digestAInput += digestB
            } else {
                digestAInput += passwordBytes
            }
            length >>= 1
        }

        var digestA = sha512(digestAInput)

        // Step 11: Digest DP = SHA512(password repeated)
        var dpInput = [UInt8]()
        for _ in 0 ..< passwordBytes.count {
            dpInput += passwordBytes
        }
        let digestDP = sha512(dpInput)

        // Step 12: Produce P string
        var p = [UInt8]()
        remaining = passwordBytes.count
        while remaining > 64 {
            p += digestDP
            remaining -= 64
        }
        p += Array(digestDP.prefix(remaining))

        // Step 13: Digest DS = SHA512(salt repeated)
        var dsInput = [UInt8]()
        for _ in 0 ..< (16 + Int(digestA[0])) {
            dsInput += saltBytes
        }
        let digestDS = sha512(dsInput)

        // Step 14: Produce S string
        var s = [UInt8]()
        remaining = saltBytes.count
        while remaining > 64 {
            s += digestDS
            remaining -= 64
        }
        s += Array(digestDS.prefix(remaining))

        // Step 15: 5000 rounds
        for i in 0 ..< rounds {
            var cInput = [UInt8]()
            if i & 1 != 0 { cInput += p } else { cInput += digestA }
            if i % 3 != 0 { cInput += s }
            if i % 7 != 0 { cInput += p }
            if i & 1 != 0 { cInput += digestA } else { cInput += p }
            digestA = sha512(cInput)
        }

        // Step 16: Encode output
        let output = encode64(digestA)

        let saltStr =
            String(bytes: saltBytes, encoding: .utf8)
                ?? String(saltBytes.map { Character(UnicodeScalar($0)) })
        if rounds == 5_000 {
            return "$6$\(saltStr)$\(output)"
        } else {
            return "$6$rounds=\(rounds)$\(saltStr)$\(output)"
        }
    }

    private static func sha512(_ data: [UInt8]) -> [UInt8] {
        Array(SHA512.hash(data: data))
    }

    private static func encode64(_ hash: [UInt8]) -> String {
        precondition(hash.count == 64, "SHA-512 hash must be exactly 64 bytes")

        // SHA-512 crypt uses a specific byte-reordering for base64 encoding
        let order: [(Int, Int, Int)] = [
            (0, 21, 42), (22, 43, 1), (44, 2, 23),
            (3, 24, 45), (25, 46, 4), (47, 5, 26),
            (6, 27, 48), (28, 49, 7), (50, 8, 29),
            (9, 30, 51), (31, 52, 10), (53, 11, 32),
            (12, 33, 54), (34, 55, 13), (56, 14, 35),
            (15, 36, 57), (37, 58, 16), (59, 17, 38),
            (18, 39, 60), (40, 61, 19), (62, 20, 41),
        ]

        var result = [UInt8]()

        for (a, b, c) in order {
            let v = (Int(hash[a]) << 16) | (Int(hash[b]) << 8) | Int(hash[c])
            result.append(itoa64[v & 0x3F])
            result.append(itoa64[(v >> 6) & 0x3F])
            result.append(itoa64[(v >> 12) & 0x3F])
            result.append(itoa64[(v >> 18) & 0x3F])
        }

        // Last byte (index 63)
        let v = Int(hash[63])
        result.append(itoa64[v & 0x3F])
        result.append(itoa64[(v >> 6) & 0x3F])

        return String(bytes: result, encoding: .ascii) ?? ""
    }
}
