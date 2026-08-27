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
    /// Guest-local Ollama when a GPU is attached (PAS-275). Host Ollama is not forwarded.
    public static let guestOllamaBaseURL = GPUPassthroughService.guestOllamaPath

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

    public static let defaultOpenAIAPIKey = "ollama"

    public static func isShellSafeOpenAIAPIKey(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { ch in
            ch.isASCII && (ch.isLetter || ch.isNumber || "._+=-".contains(ch))
        }
    }

    public static func normalizeOpenAIAPIKey(_ raw: String?, required: Bool = false) throws -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            if required { throw BarkVisorError.badRequest("OPENAI_API_KEY is required") }
            return defaultOpenAIAPIKey
        }
        guard isShellSafeOpenAIAPIKey(trimmed) else {
            throw BarkVisorError.badRequest("OPENAI_API_KEY is invalid")
        }
        return trimmed
    }

    public static func posixSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func openaiAPIKeyForHomeGrant(_ raw: String?) throws -> String {
        guard let raw else { return defaultOpenAIAPIKey }
        return try normalizeOpenAIAPIKey(raw, required: true)
    }

    /// Unquoted `/etc/default/barkvisor-openai` assignment. GPU rewrite keeps a grant.
    public static func openaiAPIKeyFromUserData(_ userData: String?) -> String? {
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

    public static func usesDeviceOllama(_ url: String) -> Bool {
        guard let comps = URLComponents(string: url),
              comps.user == nil, comps.password == nil,
              comps.scheme?.lowercased() == "http",
              comps.host == deviceOllamaHost
        else { return false }
        let port = comps.port ?? 80
        return port == deviceOllamaPort
    }

    public static func userData(
        openaiBaseURL: String,
        openaiAPIKey: String = defaultOpenAIAPIKey,
        installGuestOllama: Bool = false,
    ) -> String {
        let quotedURL = posixSingleQuoted(openaiBaseURL)
        let quotedKey = posixSingleQuoted(openaiAPIKey)
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
        let guestOllamaFiles: String
        let guestOllamaRun: String
        if installGuestOllama {
            guestOllamaFiles = """
                  - path: /usr/local/bin/barkvisor-guest-ollama
                    permissions: '0755'
                    content: |
                      #!/bin/bash
                      set -euo pipefail
                      if ! command -v ollama >/dev/null 2>&1; then
                        curl -fsSL https://ollama.com/install.sh | sh
                      fi
                      systemctl enable --now ollama || true
            """
            guestOllamaRun = "          - [ bash, /usr/local/bin/barkvisor-guest-ollama ]\n"
        } else {
            guestOllamaFiles = ""
            guestOllamaRun = ""
        }
        let yaml = """
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
        \(guestOllamaFiles)runcmd:
          - chown ubuntu:ubuntu /etc/default/barkvisor-openai /etc/profile.d/barkvisor-openai.sh
          - install -d -m 1777 /var/lib/barkvisor
          - git config --system core.hooksPath /etc/git-hooks
          - systemctl enable --now qemu-guest-agent
          - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
          - systemctl enable --now ttyd

        """
        return yaml + guestOllamaRun
    }

    public static func isManagedUserData(_ userData: String?) -> Bool {
        (userData ?? "").contains("barkvisor-coding-agent-setup")
    }

    public static func userDataForGPU(gpuAttached: Bool, existingUserData: String? = nil) -> String {
        let key = openaiAPIKeyFromUserData(existingUserData) ?? defaultOpenAIAPIKey
        return userData(
            openaiBaseURL: gpuAttached ? guestOllamaBaseURL : homeOllamaGrantURL,
            openaiAPIKey: key,
            installGuestOllama: gpuAttached,
        )
    }

    public static func cloudInitInstanceID(vmID: String, gpuAttached: Bool) -> String {
        gpuAttached ? "\(vmID)-gpu" : vmID
    }

    /// Managed Coding Agent ISOs flip `instance-id` so cloud-init re-runs on GPU attach/detach.
    public static func cloudInitInstanceID(
        vmID: String,
        userData: String?,
        gpuDevices: [GPUPassthroughDevice]?,
    ) -> String? {
        guard isManagedUserData(userData) else { return nil }
        return cloudInitInstanceID(
            vmID: vmID, gpuAttached: GPUPassthroughService.hasDisplayGPU(gpuDevices),
        )
    }

    public static func applyingCreateDefaults(
        params: CreateVMParams,
        imageName: String?,
        imageSlug: String? = nil,
        grantPlaintext: String? = nil,
    ) throws -> CreateVMParams {
        guard matches(name: imageName, slug: imageSlug) else { return params }
        let klass = defaultWorkloadClass(explicit: params.workloadClass)
        let existing = params.cloudInit?.userData?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gpuAttached = GPUPassthroughService.hasDisplayGPU(params.gpuDevices)
        let userData: String
        if existing.isEmpty {
            let defaultURL = gpuAttached ? guestOllamaBaseURL : homeOllamaGrantURL
            let key = try openaiAPIKeyForHomeGrant(grantPlaintext)
            userData = Self.userData(
                openaiBaseURL: defaultURL, openaiAPIKey: key, installGuestOllama: gpuAttached,
            )
            try CloudInitService.validateUserData(userData)
        } else {
            userData = existing
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
            gpuDevices: params.gpuDevices,
            description: params.description,
            bootOrder: params.bootOrder,
            displayResolution: params.displayResolution,
            uefi: params.uefi,
            tpmEnabled: params.tpmEnabled,
            overrides: params.overrides,
            health: params.health,
            workloadClass: klass,
            allowCatalogIdentityKeys: params.allowCatalogIdentityKeys,
        )
    }
}
