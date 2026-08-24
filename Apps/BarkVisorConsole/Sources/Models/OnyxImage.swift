import Foundation

/// Mirrors BarkVisorCore.OnyxImage for the native console.
enum OnyxImage {
    static let name = "Onyx"
    static let slugs: Set<String> = ["onyx", "onyx-arm64", "onyx-x86_64"]
    static let ollamaAPIBase = "http://10.0.2.2:11434"
    static let defaultMemoryMB = 2_048
    static let defaultDiskGB = 20
    static let webUIPort = 80
    static let releaseTag = "v4.6.2"
    static let gitURL = "https://github.com/onyx-dot-app/onyx.git"
    static let setupMarker = "barkvisor-onyx-setup"
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

    static func userData() -> String {
        let marker = "\(allowHostOllamaYAML)\n"
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
              printf '%s\n' \\
                "IMAGE_TAG=\(tag)" \\
                "USER_AUTH_SECRET=$SECRET" \\
                "POSTGRES_USER=postgres" \\
                "POSTGRES_PASSWORD=$PGPASS" \\
                "AUTH_TYPE=basic" \\
                "DISABLE_VECTOR_DB=true" \\
                "FILE_STORE_BACKEND=postgres" \\
                "CACHE_BACKEND=postgres" \\
                "AUTH_BACKEND=postgres" \\
                "COMPOSE_PROFILES=" \\
                "WEB_DOMAIN=http://127.0.0.1" \\
                "DISABLE_TELEMETRY=true" \\
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
              BODY=$(jq -n --arg base "$OLLAMA" --argjson models "$CONFIGS" \\
                '{name:"Home Ollama",provider:"ollama",api_base:$base,is_public:true,model_configurations:$models}')
              curl -fsS -X PUT "$BASE/api/admin/llm/provider?is_creation=true" \\
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
}
