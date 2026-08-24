export const ONYX_NAME = 'Onyx'
export const ONYX_SLUGS = ['onyx', 'onyx-arm64', 'onyx-x86_64'] as const
export const ONYX_OLLAMA_API_BASE = 'http://10.0.2.2:11434'
export const ONYX_WEB_UI_PORT = 80
export const ONYX_RELEASE_TAG = 'v4.6.2'
export const ONYX_GIT_URL = 'https://github.com/onyx-dot-app/onyx.git'
export const ONYX_SETUP_MARKER = 'barkvisor-onyx-setup'
export const ALLOW_HOST_OLLAMA_YAML = 'barkvisor_allow_host_ollama: true'
export const ONYX_DEFAULT_MEMORY_MB = 2048
export const ONYX_DEFAULT_DISK_GB = 20

export function isOnyxImage(img: {
  name?: string | null
  slug?: string | null
} | null | undefined): boolean {
  if (!img) return false
  const slug = img.slug?.trim()
  if (slug) return (ONYX_SLUGS as readonly string[]).includes(slug)
  return (img.name ?? '').trim().toLowerCase() === ONYX_NAME.toLowerCase()
}

export function onyxUserData(): string {
  return `${ALLOW_HOST_OLLAMA_YAML}
package_update: true
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
  - path: /usr/local/bin/${ONYX_SETUP_MARKER}
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      install -d -m 0755 /opt/onyx /var/lib/barkvisor /etc/onyx
      if [ ! -d /opt/onyx/.git ]; then
        git clone --depth 1 --branch ${ONYX_RELEASE_TAG} ${ONYX_GIT_URL} /opt/onyx
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
      printf '%s\\n' \\
        "IMAGE_TAG=${ONYX_RELEASE_TAG}" \\
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
      OLLAMA=${ONYX_OLLAMA_API_BASE}
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
  - [ bash, /usr/local/bin/${ONYX_SETUP_MARKER} ]
  - systemctl enable barkvisor-onyx
`
}

export function mergeOnyxUserData(
  existing: string,
  img: { name?: string | null; slug?: string | null } | null | undefined,
): string {
  const trimmed = existing.trim()
  if (trimmed) return trimmed
  if (!isOnyxImage(img)) return existing
  return onyxUserData()
}
