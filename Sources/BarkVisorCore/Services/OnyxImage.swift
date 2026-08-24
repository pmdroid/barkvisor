import Foundation

/// Onyx Lite Template: Ubuntu 24.04 cloud image, Agent cage, Home Ollama
/// at `http://10.0.2.2:11434` (native API, not Device `:7777`).
public enum OnyxImage {
    public static let name = "Onyx"
    public static let templateSlug = "onyx"
    public static let slugPrefix = "onyx-"
    public static let arm64Slug = "onyx-arm64"
    public static let amd64Slug = "onyx-x86_64"
    public static let slugs: Set<String> = [arm64Slug, amd64Slug, templateSlug]

    /// Native Ollama in the cage (not OpenAI-compat `/v1`).
    public static let ollamaAPIBase = "http://\(AgentNetworkCage.slirpGateway):\(AgentNetworkCage.ollamaPort)"
    public static let defaultCPUCount = 2
    public static let defaultMemoryMB = 2_048
    public static let defaultDiskGB = 20
    /// nginx in the Lite compose stack (`HOST_PORT_80`, guest :80).
    public static let webUIPort = 80
    /// Pinned Onyx release (compose `IMAGE_TAG` and git clone `--branch`).
    public static let releaseTag = "v4.6.2"
    public static let gitURL = "https://github.com/onyx-dot-app/onyx.git"
    public static let setupMarker = "barkvisor-onyx-setup"

    public static func matches(name: String?, slug: String? = nil) -> Bool {
        if let slug {
            let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return slugs.contains(trimmed) }
        }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.compare(Self.name, options: [.caseInsensitive]) == .orderedSame
    }

    public static func defaultWorkloadClass(explicit: String?) -> String {
        let trimmed = explicit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { return WorkloadClass.agent.rawValue }
        return trimmed
    }

    public static func isManagedUserData(_ userData: String?) -> Bool {
        (userData ?? "").contains(setupMarker)
    }

    public static func wantsWebUI(userData: String?) -> Bool {
        isManagedUserData(userData)
    }

    /// Template deploy: catalog `userDataTemplate` may be empty; fill from here.
    public static func deployUserData(
        templateName: String?,
        templateSlug: String?,
        rendered: String,
    ) -> String {
        if matches(name: templateName, slug: templateSlug) { return userData() }
        return rendered
    }

    public static func userData() -> String {
        let marker = "\(AgentNetworkCage.allowHostOllamaYAML)\n"
        let tag = releaseTag
        let git = gitURL
        let ollama = ollamaAPIBase
        let setup = setupMarker
        return """
        \(marker)package_update: true
        packages:
          - docker.io
          - docker-compose-v2
          - git
          - curl
          - jq
          - openssl
          - ca-certificates
          - qemu-guest-agent
        write_files:
          - path: /usr/local/bin/\(setup)
            permissions: '0755'
            content: |
              #!/bin/bash
              set -euo pipefail
              install -d -m 0755 /opt/onyx /var/lib/barkvisor /etc/onyx
              if [ ! -d /opt/onyx/.git ]; then
                git clone --depth 1 --branch \(tag) \(git) /opt/onyx
              fi
              COMPOSE=/opt/onyx/deployment/docker_compose
              if [ ! -f /etc/onyx/user-auth-secret ]; then
                openssl rand -hex 32 > /etc/onyx/user-auth-secret
                chmod 600 /etc/onyx/user-auth-secret
              fi
              if [ ! -f /etc/onyx/postgres-password ]; then
                openssl rand -hex 16 > /etc/onyx/postgres-password
                chmod 600 /etc/onyx/postgres-password
              fi
              SECRET=$(cat /etc/onyx/user-auth-secret)
              PGPASS=$(cat /etc/onyx/postgres-password)
              printf '%s\\n' \
                "IMAGE_TAG=\(tag)" \
                "USER_AUTH_SECRET=$SECRET" \
                "POSTGRES_USER=postgres" \
                "POSTGRES_PASSWORD=$PGPASS" \
                "AUTH_TYPE=basic" \
                "DISABLE_VECTOR_DB=true" \
                "FILE_STORE_BACKEND=postgres" \
                "CACHE_BACKEND=postgres" \
                "AUTH_BACKEND=postgres" \
                "COMPOSE_PROFILES=" \
                "WEB_DOMAIN=http://127.0.0.1" \
                "DISABLE_TELEMETRY=true" \
                > "$COMPOSE/.env"
              usermod -aG docker ubuntu || true
              systemctl enable --now docker
              cd "$COMPOSE"
              docker compose -f docker-compose.yml -f docker-compose.onyx-lite.yml up -d
              /usr/local/bin/barkvisor-onyx-seed || true
          - path: /usr/local/bin/barkvisor-onyx-seed
            permissions: '0755'
            content: |
              #!/bin/bash
              set -euo pipefail
              OLLAMA=\(ollama)
              BASE=http://127.0.0.1
              for _ in $(seq 1 90); do
                if curl -fsS "$BASE/api/health" >/dev/null 2>&1; then
                  break
                fi
                sleep 5
              done
              MODELS=$(curl -fsS "$OLLAMA/api/tags" | jq -c '[.models[]?.name] // []' || echo '[]')
              CONFIGS=$(echo "$MODELS" | jq -c '[.[] | {name: ., is_visible: true}]')
              BODY=$(jq -n --arg base "$OLLAMA" --argjson models "$CONFIGS" \
                '{name:"Home Ollama",provider:"ollama",api_base:$base,is_public:true,model_configurations:$models}')
              curl -fsS -X PUT "$BASE/api/admin/llm/provider?is_creation=true" \
                -H 'Content-Type: application/json' -d "$BODY" || true
          - path: /etc/systemd/system/barkvisor-onyx.service
            permissions: '0644'
            content: |
              [Unit]
              Description=Onyx Lite
              After=docker.service network-online.target
              Wants=network-online.target docker.service
              Requires=docker.service

              [Service]
              Type=oneshot
              RemainAfterExit=yes
              WorkingDirectory=/opt/onyx/deployment/docker_compose
              ExecStart=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.onyx-lite.yml up -d
              ExecStop=/usr/bin/docker compose -f docker-compose.yml -f docker-compose.onyx-lite.yml down
              TimeoutStartSec=0

              [Install]
              WantedBy=multi-user.target
        runcmd:
          - systemctl enable --now qemu-guest-agent
          - [ bash, /usr/local/bin/\(setup) ]
          - systemctl enable barkvisor-onyx

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
        let userData: String
        if existing.isEmpty {
            userData = Self.userData()
            try CloudInitService.validateUserData(userData)
        } else {
            userData = existing
        }
        let cloudInit = CloudInitConfig(
            sshAuthorizedKeys: params.cloudInit?.sshAuthorizedKeys,
            userData: userData,
        )
        let disk = max(params.diskSizeGB ?? defaultDiskGB, defaultDiskGB)
        return CreateVMParams(
            id: params.id,
            name: params.name,
            vmType: params.vmType,
            cpuCount: max(params.cpuCount, defaultCPUCount),
            memoryMB: max(params.memoryMB, defaultMemoryMB),
            diskSizeGB: disk,
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
        )
    }
}
