import Foundation

/// One Linux Library image (arm64 + x86_64) with git, a web terminal, and
/// coding-agent CLIs (PAS-271). Presets are Device Ollama vs BYO
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
    /// Claude Code GitHub release (anthropics/claude-code SHASUMS256.txt).
    public static let claudeVersion = "2.1.241"
    public static let claudeSha256Aarch64 =
        "d3563afb0328eee644b5b830c3de42699b56a0d83de3423a466a0e2065b2417d"
    public static let claudeSha256Amd64 =
        "c171011648d71b96a0956469a46315a4c826ccba7e20854ae62aa5c776d6a794"
    /// OpenCode GitHub release tarballs (anomalyco/opencode).
    public static let opencodeVersion = "1.18.21"
    public static let opencodeSha256Aarch64 =
        "d30d2cba74617f4e7b96e25563c9572ffe453f9eae70fc0df16286813537ee72"
    public static let opencodeSha256Amd64 =
        "d910c3ed7613bb5791a328904615d41cc25b7d3a6b470e3199ab0426a995b38a"

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

    public static func normalizeOpenAIBaseURL(_ raw: String?) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return deviceOllamaBaseURL }
        if trimmed.contains(where: { ch in
            ch.isNewline || ch.isWhitespace || "\"'`$\\".contains(ch)
        }) {
            throw BarkVisorError.badRequest("OPENAI_BASE_URL is invalid")
        }
        guard let comps = URLComponents(string: trimmed),
              comps.user == nil, comps.password == nil,
              let scheme = comps.scheme?.lowercased(),
              scheme == "http" || scheme == "https", comps.host != nil
        else {
            throw BarkVisorError.badRequest("OPENAI_BASE_URL must be an http(s) URL")
        }
        return trimmed
    }

    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func usesDeviceOllama(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url),
              comps.user == nil, comps.password == nil,
              comps.scheme?.lowercased() == "http",
              comps.host == deviceOllamaHost
        else { return false }
        let port = comps.port ?? 80
        return port == deviceOllamaPort
    }

    public static func userData(openaiBaseURL: String) -> String {
        let quotedURL = posixSingleQuoted(openaiBaseURL)
        let marker = usesDeviceOllama(openaiBaseURL)
            ? "\(AgentNetworkCage.allowHostOllamaYAML)\n"
            : ""
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
          - path: /etc/profile.d/barkvisor-openai.sh
            permissions: '0644'
            content: |
              export OPENAI_BASE_URL=\(quotedURL)
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
            ? Self.userData(openaiBaseURL: deviceOllamaBaseURL)
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
