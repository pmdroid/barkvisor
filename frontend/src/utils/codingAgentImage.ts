export const CODING_AGENT_NAME = 'Coding Agent'
export const CODING_AGENT_SLUGS = ['coding-agent-arm64', 'coding-agent-x86_64'] as const
export const DEVICE_OLLAMA_BASE_URL = 'http://10.0.2.2:11434/v1'
export const TTYD_VERSION = '1.7.7'
export const TTYD_SHA256_AARCH64 =
  'b38acadd89d1d396a0f5649aa52c539edbad07f4bc7348b27b4f4b7219dd4165'
export const TTYD_SHA256_X86_64 =
  '8a217c968aba172e0dbf3f34447218dc015bc4d5e59bf51db2f2cd12b7be4f55'
export const CLAUDE_VERSION = '2.1.241'
export const CLAUDE_SHA256_AARCH64 =
  'd3563afb0328eee644b5b830c3de42699b56a0d83de3423a466a0e2065b2417d'
export const CLAUDE_SHA256_X86_64 =
  'c171011648d71b96a0956469a46315a4c826ccba7e20854ae62aa5c776d6a794'
export const OPENCODE_VERSION = '1.18.21'
export const OPENCODE_SHA256_AARCH64 =
  'd30d2cba74617f4e7b96e25563c9572ffe453f9eae70fc0df16286813537ee72'
export const OPENCODE_SHA256_X86_64 =
  'd910c3ed7613bb5791a328904615d41cc25b7d3a6b470e3199ab0426a995b38a'
export const WEB_TERMINAL_PORT = 7681
export const ALLOW_HOST_OLLAMA_YAML = 'barkvisor_allow_host_ollama: true'

export type OpenAIPreset = 'device-ollama' | 'byo'

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

export function normalizeOpenAIBaseURL(raw: string | null | undefined): string {
  const trimmed = (raw ?? '').trim()
  if (!trimmed) return DEVICE_OLLAMA_BASE_URL
  if (/[\s"'`$\\]/.test(trimmed)) throw new Error('OPENAI_BASE_URL is invalid')
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

export function posixSingleQuoted(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`
}

export function usesDeviceOllama(url: string): boolean {
  return url === DEVICE_OLLAMA_BASE_URL || url.startsWith('http://10.0.2.2:11434')
}

export function codingAgentUserData(openaiBaseURL: string): string {
  const quotedURL = posixSingleQuoted(openaiBaseURL)
  const marker = usesDeviceOllama(openaiBaseURL) ? `${ALLOW_HOST_OLLAMA_YAML}\n` : ''
  return `${marker}package_update: true
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
      export OPENAI_BASE_URL=${quotedURL}
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
      ExecStart=/usr/local/bin/ttyd --writable --port ${WEB_TERMINAL_PORT} tmux new -A -s main
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
          ttyd_arch=aarch64; ttyd_sha=${TTYD_SHA256_AARCH64}
          claude_tar=claude-linux-arm64.tar.gz; claude_sha=${CLAUDE_SHA256_AARCH64}
          oc_tar=opencode-linux-arm64.tar.gz; oc_sha=${OPENCODE_SHA256_AARCH64}
          ;;
        *)
          ttyd_arch=x86_64; ttyd_sha=${TTYD_SHA256_X86_64}
          claude_tar=claude-linux-x64.tar.gz; claude_sha=${CLAUDE_SHA256_X86_64}
          oc_tar=opencode-linux-x64.tar.gz; oc_sha=${OPENCODE_SHA256_X86_64}
          ;;
      esac
      install_sha() {
        local url="$1" sha="$2" dest="$3"
        local tmp
        tmp=$(mktemp)
        curl -fsSL "$url" -o "$tmp"
        echo "\${sha}  \${tmp}" | sha256sum -c -
        install -m 0755 "$tmp" "$dest"
        rm -f "$tmp"
      }
      install_tarball_bin() {
        local url="$1" sha="$2" bin="$3"
        local tmp dir
        tmp=$(mktemp)
        dir=$(mktemp -d)
        curl -fsSL "$url" -o "$tmp"
        echo "\${sha}  \${tmp}" | sha256sum -c -
        tar -xzf "$tmp" -C "$dir"
        install -m 0755 "$dir/$bin" "/usr/local/bin/$bin"
        rm -rf "$tmp" "$dir"
      }
      install_sha "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.\${ttyd_arch}" "$ttyd_sha" /usr/local/bin/ttyd
      install_tarball_bin "https://github.com/anthropics/claude-code/releases/download/v${CLAUDE_VERSION}/\${claude_tar}" "$claude_sha" claude
      install_tarball_bin "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/\${oc_tar}" "$oc_sha" opencode
runcmd:
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
  const url = preset === 'byo' ? normalizeOpenAIBaseURL(byoURL) : DEVICE_OLLAMA_BASE_URL
  return codingAgentUserData(url)
}
