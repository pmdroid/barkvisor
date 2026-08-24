import Foundation

/// Mirrors BarkVisorCore.CodingAgentImage for the native console (PAS-271).
enum CodingAgentImage {
    static let name = "Coding Agent"
    static let slugs: Set<String> = ["coding-agent-arm64", "coding-agent-x86_64"]
    static let deviceOllamaBaseURL = "http://10.0.2.2:11434/v1"
    static let homeOllamaGrantURL = deviceOllamaBaseURL
    static let defaultMemoryMB = 2_048
    static let defaultDiskGB = 20
    static let webTerminalPort = 7_681
    static let ttydVersion = "1.7.7"
    static let ttydSha256Aarch64 =
        "b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165"
    static let ttydSha256Amd64 =
        "8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55"
    static let claudeVersion = "2.1.241"
    static let claudeSha256Aarch64 =
        "d3563afb0328eee644b5b830c3de42699b56a0d83de3423a466a0e2065b2417d"
    static let claudeSha256Amd64 =
        "c171011648d71b96a0956469a46315a4c826ccba7e20854ae62aa5c776d6a794"
    static let opencodeVersion = "1.18.21"
    static let opencodeSha256Aarch64 =
        "d30d2cba74617f4e7b96e25563c9572ffe453f9eae70fc0df16286813537ee72"
    static let opencodeSha256Amd64 =
        "d910c3ed7613bb5791a328904615d41cc25b7d3a6b470e3199ab0426a995b38a"
    static let allowHostOllamaYAML = "barkvisor_allow_host_ollama: true"

    static func matches(name: String?, slug: String? = nil) -> Bool {
        if let slug {
            let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return slugs.contains(trimmed) }
        }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.compare(Self.name, options: [.caseInsensitive]) == .orderedSame
    }

    static func defaultClass(forName name: String?) -> String {
        matches(name: name) ? "agent" : "house"
    }

    static func normalizeOpenAIBaseURL(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return homeOllamaGrantURL }
        if trimmed.contains(where: { ch in
            ch.isNewline || ch.isWhitespace || "\"'`$\\".contains(ch)
        }) {
            throw CreateWorkload.DraftError.invalidOpenAIBaseURL
        }
        guard let comps = URLComponents(string: trimmed),
              comps.user == nil, comps.password == nil,
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", comps.host != nil
        else {
            throw CreateWorkload.DraftError.invalidOpenAIBaseURL
        }
        return trimmed
    }

    static let defaultOpenAIAPIKey = "ollama"

    static func openaiAPIKeyForHomeGrant(_ raw: String?) throws -> String {
        guard let raw else { return defaultOpenAIAPIKey }
        return try normalizeOpenAIAPIKey(raw, required: true)
    }

    static func openaiAPIKeyFromUserData(_ userData: String?) -> String? {
        guard let userData, !userData.isEmpty else { return nil }
        let pattern = #"(?m)^[ \t]*OPENAI_API_KEY=([A-Za-z0-9._+=-]+)[ \t]*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: userData, range: NSRange(userData.startIndex..., in: userData),
              ),
              let range = Range(match.range(at: 1), in: userData)
        else { return nil }
        let value = String(userData[range])
        return isShellSafeOpenAIAPIKey(value) ? value : nil
    }

    static func isShellSafeOpenAIAPIKey(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || "._+=-".contains(ch))
        }
    }

    static func normalizeOpenAIAPIKey(_ raw: String?, required: Bool = false) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if required { throw CreateWorkload.DraftError.missingOpenAIAPIKey }
            return defaultOpenAIAPIKey
        }
        guard isShellSafeOpenAIAPIKey(trimmed) else {
            throw CreateWorkload.DraftError.invalidOpenAIAPIKey
        }
        return trimmed
    }

    static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isShellSafeOpenAIBaseURL(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ":/._%-".contains(ch))
        }
    }

    static func usesDeviceOllama(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url),
              comps.user == nil, comps.password == nil,
              comps.scheme?.lowercased() == "http",
              comps.host == "10.0.2.2"
        else { return false }
        return (comps.port ?? 80) == 11_434
    }

    static func userData(
        openaiBaseURL: String,
        openaiAPIKey: String = defaultOpenAIAPIKey,
    ) -> String {
        let quotedURL = posixSingleQuoted(openaiBaseURL)
        let quotedKey = posixSingleQuoted(openaiAPIKey)
        let marker = usesDeviceOllama(openaiBaseURL) ? "\(allowHostOllamaYAML)\n" : ""
        let ttydVer = ttydVersion
        let shaArm = ttydSha256Aarch64
        let shaX64 = ttydSha256Amd64
        let claudeVer = claudeVersion
        let claudeArm = claudeSha256Aarch64
        let claudeX64 = claudeSha256Amd64
        let ocVer = opencodeVersion
        let ocArm = opencodeSha256Aarch64
        let ocX64 = opencodeSha256Amd64
        let ttydPort = webTerminalPort
        return """
        \(marker)package_update: true
        packages:
          - git
          - qemu-guest-agent
          - tmux
          - curl
          - jq
          - ca-certificates
        write_files:
          - path: /etc/default/barkvisor-openai
            permissions: '0600'
            content: |
              OPENAI_BASE_URL=\(openaiBaseURL)
              OPENAI_API_KEY=\(openaiAPIKey)
          - path: /etc/profile.d/barkvisor-openai.sh
            permissions: '0600'
            content: |
              export OPENAI_BASE_URL=\(quotedURL)
              export OPENAI_API_KEY=\(quotedKey)
          - path: /etc/systemd/system/ttyd.service
            permissions: '0644'
            content: |
              [Unit]
              Description=ttyd web terminal
              After=network-online.target
              Wants=network-online.target

              [Service]
              Type=simple
              User=ubuntu
              EnvironmentFile=-/etc/default/barkvisor-openai
              ExecStart=/usr/local/bin/ttyd --writable --port \(ttydPort) tmux new -A -s main
              Restart=on-failure

              [Install]
              WantedBy=multi-user.target
          - path: /etc/git-hooks/pre-push
            permissions: '0755'
            content: |
              #!/bin/bash
              install -d -m 1777 /var/lib/barkvisor
              date -u +%Y-%m-%dT%H:%M:%SZ > /var/lib/barkvisor/last-git-push
          - path: /usr/local/bin/barkvisor-coding-agent-setup
            permissions: '0755'
            content: |
              #!/bin/bash
              set -euo pipefail
              arch=$(uname -m)
              case "$arch" in
                aarch64|arm64)
                  ttyd_arch=aarch64; ttyd_sha=\(shaArm)
                  claude_tar=claude-linux-arm64.tar.gz; claude_sha=\(claudeArm)
                  oc_tar=opencode-linux-arm64.tar.gz; oc_sha=\(ocArm)
                  ;;
                *)
                  ttyd_arch=x86_64; ttyd_sha=\(shaX64)
                  claude_tar=claude-linux-x64.tar.gz; claude_sha=\(claudeX64)
                  oc_tar=opencode-linux-x64.tar.gz; oc_sha=\(ocX64)
                  ;;
              esac
              install_sha() {
                local url="$1" sha="$2" dest="$3"
                local tmp
                tmp=$(mktemp)
                curl -fsSL "$url" -o "$tmp"
                echo "${sha}  ${tmp}" | sha256sum -c -
                install -m 0755 "$tmp" "$dest"
                rm -f "$tmp"
              }
              install_tarball_bin() {
                local url="$1" sha="$2" bin="$3"
                local tmp dir
                tmp=$(mktemp)
                dir=$(mktemp -d)
                curl -fsSL "$url" -o "$tmp"
                echo "${sha}  ${tmp}" | sha256sum -c -
                tar -xzf "$tmp" -C "$dir"
                install -m 0755 "$dir/$bin" "/usr/local/bin/$bin"
                rm -rf "$tmp" "$dir"
              }
              install_sha "https://github.com/tsl0922/ttyd/releases/download/\(ttydVer)/ttyd.${ttyd_arch}" "$ttyd_sha" /usr/local/bin/ttyd
              install_tarball_bin "https://github.com/anthropics/claude-code/releases/download/v\(claudeVer)/${claude_tar}" "$claude_sha" claude
              install_tarball_bin "https://github.com/anomalyco/opencode/releases/download/v\(ocVer)/${oc_tar}" "$oc_sha" opencode
        runcmd:
          - chown ubuntu:ubuntu /etc/default/barkvisor-openai /etc/profile.d/barkvisor-openai.sh
          - install -d -m 1777 /var/lib/barkvisor
          - git config --system core.hooksPath /etc/git-hooks
          - systemctl enable --now qemu-guest-agent
          - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
          - systemctl enable --now ttyd
        """
    }
}
