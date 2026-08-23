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
        if trimmed.contains(where: { $0.isNewline || $0 == "\"" || $0.isWhitespace }) {
            throw CreateWorkload.DraftError.invalidOpenAIBaseURL
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else {
            throw CreateWorkload.DraftError.invalidOpenAIBaseURL
        }
        return trimmed
    }

    static func userData(openaiBaseURL: String) -> String {
        let ttydVer = ttydVersion
        let shaArm = ttydSha256Aarch64
        let shaX64 = ttydSha256Amd64
        let ttydPort = webTerminalPort
        return """
        package_update: true
        packages:
          - git
          - qemu-guest-agent
          - tmux
          - curl
          - jq
          - ca-certificates
        write_files:
          - path: /etc/profile.d/barkvisor-openai.sh
            permissions: '0644'
            content: |
              export OPENAI_BASE_URL="\(openaiBaseURL)"
              export OPENAI_API_KEY="${OPENAI_API_KEY:-ollama}"
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
              ExecStart=/usr/local/bin/ttyd --writable --port \(ttydPort) tmux new -A -s main
              Restart=on-failure

              [Install]
              WantedBy=multi-user.target
          - path: /usr/local/bin/barkvisor-coding-agent-setup
            permissions: '0755'
            content: |
              #!/bin/bash
              set -euo pipefail
              arch=$(uname -m)
              case "$arch" in
                aarch64|arm64) ttyd_arch=aarch64; ttyd_sha=\(shaArm) ;;
                *) ttyd_arch=x86_64; ttyd_sha=\(shaX64) ;;
              esac
              tmp=$(mktemp)
              curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/\(ttydVer)/ttyd.${ttyd_arch}" -o "$tmp"
              echo "${ttyd_sha}  $tmp" | sha256sum -c -
              install -m 0755 "$tmp" /usr/local/bin/ttyd
              rm -f "$tmp"
              if id ubuntu >/dev/null 2>&1; then
                su -s /bin/bash -c 'curl -fsSL https://claude.ai/install.sh | bash' ubuntu || true
                su -s /bin/bash -c 'curl -fsSL https://opencode.ai/install | bash' ubuntu || true
                for bin in /home/ubuntu/.local/bin/claude /home/ubuntu/.local/bin/opencode /home/ubuntu/.opencode/bin/opencode; do
                  if [ -x "$bin" ]; then
                    install -m 0755 "$bin" "/usr/local/bin/$(basename "$bin")" || true
                  fi
                done
              fi
        runcmd:
          - systemctl enable --now qemu-guest-agent
          - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
          - systemctl enable --now ttyd
        """
    }
}
