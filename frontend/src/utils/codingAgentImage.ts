export const CODING_AGENT_NAME = 'Coding Agent'
export const CODING_AGENT_SLUGS = ['coding-agent-arm64', 'coding-agent-x86_64'] as const
export const DEVICE_OLLAMA_BASE_URL = 'http://10.0.2.2:11434/v1'
export const HOME_OLLAMA_GRANT_URL = DEVICE_OLLAMA_BASE_URL
export const TTYD_VERSION = '1.7.7'
export const TTYD_SHA256_AARCH64 =
  'b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165'
export const TTYD_SHA256_X86_64 =
  '8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55'
export const WEB_TERMINAL_PORT = 7681

export type OpenAIPreset = 'home-ollama' | 'device-ollama' | 'byo'

export function isHomeOllamaGrant(preset: OpenAIPreset): boolean {
  return preset === 'home-ollama' || preset === 'device-ollama'
}

export function isCodingAgentImage(img: {
  name?: string | null
  slug?: string | null
} | null | undefined): boolean {
  if (!img) return false
  const slug = img.slug?.trim()
  if (slug) return (CODING_AGENT_SLUGS as readonly string[]).includes(slug)
  return (img.name ?? '').trim().toLowerCase() === CODING_AGENT_NAME.toLowerCase()
}

export function defaultWorkloadClassForImage(img: { name?: string | null; slug?: string | null } | null | undefined): 'house' | 'agent' {
  return isCodingAgentImage(img) ? 'agent' : 'house'
}

const OPENAI_BASE_URL_SAFE = /^[A-Za-z0-9:/._%-]+$/

export function isShellSafeOpenAIBaseURL(value: string): boolean {
  return OPENAI_BASE_URL_SAFE.test(value)
}

export function normalizeOpenAIBaseURL(raw: string | null | undefined): string {
  const trimmed = (raw ?? '').trim()
  if (!trimmed) return HOME_OLLAMA_GRANT_URL
  if (!isShellSafeOpenAIBaseURL(trimmed)) throw new Error('OPENAI_BASE_URL is invalid')
  let url: URL
  try {
    url = new URL(trimmed)
  } catch {
    throw new Error('OPENAI_BASE_URL must be an http(s) URL')
  }
  if (url.protocol !== 'http:' && url.protocol !== 'https:') {
    throw new Error('OPENAI_BASE_URL must be an http(s) URL')
  }
  return trimmed
}

export function codingAgentUserData(openaiBaseURL: string): string {
  const url = openaiBaseURL
  return `package_update: true
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
      OPENAI_BASE_URL=${url}
      OPENAI_API_KEY=ollama
  - path: /etc/profile.d/barkvisor-openai.sh
    permissions: '0644'
    content: |
      export OPENAI_BASE_URL='${url}'
      export OPENAI_API_KEY="\${OPENAI_API_KEY:-ollama}"
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
      ExecStart=/usr/local/bin/ttyd --writable --port ${WEB_TERMINAL_PORT} tmux new -A -s main
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
        aarch64|arm64) ttyd_arch=aarch64; ttyd_sha=${TTYD_SHA256_AARCH64} ;;
        *) ttyd_arch=x86_64; ttyd_sha=${TTYD_SHA256_X86_64} ;;
      esac
      tmp=$(mktemp)
      curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.\${ttyd_arch}" -o "$tmp"
      echo "\${ttyd_sha}  $tmp" | sha256sum -c -
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
  - install -d -m 1777 /var/lib/barkvisor
  - git config --system core.hooksPath /etc/git-hooks
  - systemctl enable --now qemu-guest-agent
  - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
  - systemctl enable --now ttyd
`
}

export function mergeCodingAgentUserData(
  existing: string,
  img: { name?: string | null; slug?: string | null } | null | undefined,
  preset: OpenAIPreset,
  byoURL: string,
): string {
  const trimmed = existing.trim()
  if (trimmed) return trimmed
  if (!isCodingAgentImage(img)) return existing
  const url = isHomeOllamaGrant(preset) ? HOME_OLLAMA_GRANT_URL : normalizeOpenAIBaseURL(byoURL)
  return codingAgentUserData(url)
}
