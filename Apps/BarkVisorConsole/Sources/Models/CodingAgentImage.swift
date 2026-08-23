import Foundation

/// Mirrors BarkVisorCore.CodingAgentImage for the native console (PAS-271).
enum CodingAgentImage {
    static let name = "Coding Agent"
    static let slugs: Set<String> = ["coding-agent-arm64", "coding-agent-x86_64"]
    static let deviceOllamaBaseURL = "http://10.0.2.2:11434/v1"
    static let defaultMemoryMB = 2_048
    static let defaultDiskGB = 20

    static func matches(name: String?, slug: String? = nil) -> Bool {
        if let slug, slugs.contains(slug) { return true }
        return (name ?? "").localizedCaseInsensitiveContains("coding agent")
    }

    static func normalizeOpenAIBaseURL(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return deviceOllamaBaseURL }
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
        """
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
          - path: /usr/local/bin/barkvisor-coding-agent-setup
            permissions: '0755'
            content: |
              #!/bin/bash
              set -euo pipefail
              arch=$(uname -m)
              case "$arch" in
                aarch64|arm64) ttyd_arch=aarch64 ;;
                *) ttyd_arch=x86_64 ;;
              esac
              if [ ! -x /usr/local/bin/ttyd ]; then
                curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${ttyd_arch}" -o /usr/local/bin/ttyd
                chmod +x /usr/local/bin/ttyd
              fi
              curl -fsSL https://claude.ai/install.sh | bash || true
              curl -fsSL https://opencode.ai/install | bash || true
        runcmd:
          - systemctl enable --now qemu-guest-agent
          - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
        """
    }
}
