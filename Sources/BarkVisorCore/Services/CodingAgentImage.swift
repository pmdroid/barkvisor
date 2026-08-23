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

    public static func matches(name: String?, slug: String? = nil) -> Bool {
        if let slug, slugs.contains(slug) { return true }
        let haystack = (name ?? "").lowercased()
        return haystack.contains("coding agent")
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
        if trimmed.contains(where: { $0.isNewline || $0 == "\"" || $0.isWhitespace }) {
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
              export OPENAI_BASE_URL="\(url)"
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
