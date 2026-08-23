import Foundation

/// One Linux Library image (arm64 + x86_64) with git, a web terminal, and
/// coding-agent CLIs (PAS-271). Presets are Home Ollama grant vs BYO
/// `OPENAI_BASE_URL`, not a second disk image.
public enum CodingAgentImage {
    public static let name = "Coding Agent"
    public static let slugPrefix = "coding-agent-"
    public static let arm64Slug = "coding-agent-arm64"
    public static let amd64Slug = "coding-agent-x86_64"
    public static let slugs: Set<String> = [arm64Slug, amd64Slug]

    public static let deviceOllamaHost = AgentNetworkCage.slirpGateway
    public static let deviceOllamaPort = AgentNetworkCage.ollamaPort
    public static let deviceOllamaBaseURL = "http://\(deviceOllamaHost):\(deviceOllamaPort)/v1"
    /// Home Ollama grant (PAS-272). Same slirp URL; the cage guestfwd is the grant.
    public static let homeOllamaGrantURL = deviceOllamaBaseURL

    public static let defaultCPUCount = 2
    public static let defaultMemoryMB = 2_048
    public static let defaultDiskGB = 20
    public static let webTerminalPort = 7_681
    public static let ttydVersion = "1.7.7"
    /// ttyd 1.7.7 SHA256SUMS (github.com/tsl0922/ttyd).
    public static let ttydSha256Aarch64 =
        "b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165"
    public static let ttydSha256Amd64 =
        "8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55"

    public static func matches(name: String?, slug: String? = nil) -> Bool {
        if let slug {
            let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return slugs.contains(trimmed) }
        }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.compare(Self.name, options: [.caseInsensitive]) == .orderedSame
    }

    /// Empty / omitted class on this image becomes Agent. Explicit `house` stays house.
    public static func defaultWorkloadClass(explicit: String?) -> String {
        let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return WorkloadClass.agent.rawValue }
        return trimmed
    }

    /// Letters, digits, and `:/._%-` only so the value is safe in `/etc/profile.d`
    /// (single-quoted) and in a systemd `EnvironmentFile` (no shell).
    public static func isShellSafeOpenAIBaseURL(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || ":/._%-".contains(ch))
        }
    }

    public static func normalizeOpenAIBaseURL(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return deviceOllamaBaseURL }
        guard isShellSafeOpenAIBaseURL(trimmed) else {
            throw BarkVisorError.badRequest("OPENAI_BASE_URL is invalid")
        }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil
        else {
            throw BarkVisorError.badRequest("OPENAI_BASE_URL must be an http(s) URL")
        }
        return trimmed
    }

    public static func userData(openaiBaseURL: String) -> String {
        let url = openaiBaseURL
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
          - path: /etc/default/barkvisor-openai
            permissions: '0644'
            content: |
              OPENAI_BASE_URL=\(url)
              OPENAI_API_KEY=ollama
          - path: /etc/profile.d/barkvisor-openai.sh
            permissions: '0644'
            content: |
              export OPENAI_BASE_URL='\(url)'
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
              EnvironmentFile=-/etc/default/barkvisor-openai
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

    public static func applyingCreateDefaults(
        params: CreateVMParams,
        imageName: String?,
        imageSlug: String? = nil,
    ) throws -> CreateVMParams {
        guard matches(name: imageName, slug: imageSlug) else { return params }
        let klass = defaultWorkloadClass(explicit: params.workloadClass)
        let existing = params.cloudInit?.userData?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userData = existing.isEmpty
            ? Self.userData(openaiBaseURL: homeOllamaGrantURL)
            : existing
        if existing.isEmpty {
            try CloudInitService.validateUserData(userData)
        }
        let cloudInit = CloudInitConfig(
            sshAuthorizedKeys: params.cloudInit?.sshAuthorizedKeys,
            userData: userData,
        )
        return CreateVMParams(
            id: params.id,
            name: params.name,
            vmType: params.vmType,
            cpuCount: params.cpuCount,
            memoryMB: params.memoryMB,
            diskSizeGB: params.diskSizeGB,
            isoId: params.isoId,
            cloudImageId: params.cloudImageId,
            cloudInit: cloudInit,
            networkId: params.networkId,
            existingDiskId: params.existingDiskId,
            sharedPaths: params.sharedPaths,
            portForwards: params.portForwards,
            usbDevices: params.usbDevices,
            description: params.description,
            bootOrder: params.bootOrder,
            displayResolution: params.displayResolution,
            uefi: params.uefi,
            tpmEnabled: params.tpmEnabled,
            overrides: params.overrides,
            health: params.health,
            workloadClass: klass,
        )
    }
}
