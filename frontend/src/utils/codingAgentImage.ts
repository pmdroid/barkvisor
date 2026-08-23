export const CODING_AGENT_NAME = 'Coding Agent'
export const CODING_AGENT_SLUGS = ['coding-agent-arm64', 'coding-agent-x86_64'] as const
export const DEVICE_OLLAMA_BASE_URL = 'http://10.0.2.2:11434/v1'

export type OpenAIPreset = 'device-ollama' | 'byo'

export function isCodingAgentImage(img: {
  name?: string | null
  slug?: string | null
} | null | undefined): boolean {
  if (!img) return false
  if (img.slug && (CODING_AGENT_SLUGS as readonly string[]).includes(img.slug)) return true
  return (img.name ?? '').toLowerCase().includes('coding agent')
}

export function defaultWorkloadClassForImage(img: { name?: string | null; slug?: string | null } | null | undefined): 'house' | 'agent' {
  return isCodingAgentImage(img) ? 'agent' : 'house'
}

export function normalizeOpenAIBaseURL(raw: string | null | undefined): string {
  const trimmed = (raw ?? '').trim()
  if (!trimmed) return DEVICE_OLLAMA_BASE_URL
  if (/[\s"]/.test(trimmed)) throw new Error('OPENAI_BASE_URL is invalid')
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
  - path: /etc/profile.d/barkvisor-openai.sh
    permissions: '0644'
    content: |
      export OPENAI_BASE_URL="${url}"
      export OPENAI_API_KEY="\${OPENAI_API_KEY:-ollama}"
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
        curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.\${ttyd_arch}" -o /usr/local/bin/ttyd
        chmod +x /usr/local/bin/ttyd
      fi
      curl -fsSL https://claude.ai/install.sh | bash || true
      curl -fsSL https://opencode.ai/install | bash || true
runcmd:
  - systemctl enable --now qemu-guest-agent
  - [ bash, /usr/local/bin/barkvisor-coding-agent-setup ]
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
  const url = preset === 'byo' ? normalizeOpenAIBaseURL(byoURL) : DEVICE_OLLAMA_BASE_URL
  return codingAgentUserData(url)
}
