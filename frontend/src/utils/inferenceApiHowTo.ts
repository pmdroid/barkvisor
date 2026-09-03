/** LAN vs in-cage how-to for the OpenAI-compatible surface (GitHub #212).
 *  LAN is Home :7777 /v1/chat/completions, not Device :11434. */

export const HOME_LISTEN_PORT = 7777
export const CHAT_COMPLETIONS_PATH = '/v1/chat/completions'
export const OPENAI_V1_SUFFIX = '/v1'
export const CAGE_OPENAI_BASE_URL = 'http://10.0.2.2:11434/v1'
export const CAGE_DNS_LINE = 'Cage DNS is slirp.'
export const MISSING_INFERENCE_KEY = '<inference-key>'

export type InferenceHostRole = 'self' | 'member'

export type InferenceHowToInput = {
  role: InferenceHostRole
  originHost: string
  originPort?: number | null
  originScheme?: string | null
  memberHost?: string | null
  /** Saved advertise URL/host. Hostname only — never scheme or port. */
  advertiseHost?: string | null
  /** Tailscale MagicDNS or tailnet IP when no advertise host is set. */
  tailnetHost?: string | null
  grantPlaintext?: string | null
}

export type TailnetListenInfo = {
  available?: boolean
  ip?: string | null
  dnsName?: string | null
}

export type InferenceHowTo = {
  lanBaseURL: string
  lanCompletionsURL: string
  apiKey: string
  curl: string
  env: string
  cageBaseURL: string
  cageEnv: string
  cageDnsLine: string
}

export function stripListenHost(host: string): string {
  return host.trim().replace(/^\[/, '').replace(/\]$/, '')
}

export function formatListenHost(host: string): string {
  const h = stripListenHost(host)
  return h.includes(':') ? `[${h}]` : h
}

/** Hostname only from a saved advertise URL (`https://box.ts.net:443` → `box.ts.net`). */
export function advertiseHostName(raw?: string | null): string {
  const trimmed = (raw ?? '').trim()
  if (!trimmed) return ''
  if (trimmed.includes('://')) {
    try {
      const url = new URL(trimmed)
      return stripListenHost(url.hostname || '')
    } catch {
      return ''
    }
  }
  if (trimmed.startsWith('[')) {
    const close = trimmed.indexOf(']')
    if (close > 1) {
      const rest = trimmed.slice(close + 1)
      if (!rest || rest.startsWith(':')) {
        return stripListenHost(trimmed.slice(1, close))
      }
    }
  }
  const colon = trimmed.lastIndexOf(':')
  if (colon > 0 && trimmed.indexOf(':') === colon) {
    const after = trimmed.slice(colon + 1)
    if (after && /^\d+$/.test(after)) {
      return stripListenHost(trimmed.slice(0, colon))
    }
  }
  return stripListenHost(trimmed)
}

/** MagicDNS, then tailnet IP. Empty when Tailscale is down. */
export function tailnetListenHost(tailscale?: TailnetListenInfo | null): string {
  if (!tailscale?.available) return ''
  return stripListenHost(tailscale.dnsName ?? '') || stripListenHost(tailscale.ip ?? '')
}

export function isMagicDNSHost(host: string): boolean {
  const h = stripListenHost(host).toLowerCase()
  return h.endsWith('.ts.net') || h.endsWith('.tailscale.net')
}

export function formatDeviceURL(raw?: string | null): string {
  const host = advertiseHostName(raw)
  if (!host) return ''
  if (isMagicDNSHost(host)) return `https://${host}`
  return `http://${formatListenHost(host)}:${HOME_LISTEN_PORT}`
}

/** saved advertise host > tailnet > (member / origin). */
export function preferredListenHost(input: InferenceHowToInput): string {
  const advertised = advertiseHostName(input.advertiseHost)
  if (advertised) return advertised
  const tailnet = stripListenHost(input.tailnetHost ?? '')
  if (tailnet) return tailnet
  return ''
}

export function lanListenHost(input: InferenceHowToInput): string {
  const preferred = preferredListenHost(input)
  if (preferred) return preferred
  if (input.role === 'member') {
    const member = stripListenHost(input.memberHost ?? '')
    if (member) return member
  }
  return stripListenHost(input.originHost)
}

export function lanListenPort(input: InferenceHowToInput): number {
  if (preferredListenHost(input)) return HOME_LISTEN_PORT
  if (input.role === 'member' && stripListenHost(input.memberHost ?? '')) {
    return HOME_LISTEN_PORT
  }
  const port = input.originPort
  if (port && port > 0) return port
  return HOME_LISTEN_PORT
}

export function lanOrigin(input: InferenceHowToInput): string {
  const preferred = preferredListenHost(input)
  if (preferred) {
    return formatDeviceURL(preferred) || `http://${formatListenHost(preferred)}:${HOME_LISTEN_PORT}`
  }
  const memberDirect = Boolean(stripListenHost(input.memberHost ?? '')) && input.role === 'member'
  const rawScheme = memberDirect
    ? 'http'
    : (input.originScheme ?? 'http').replace(/:$/, '').toLowerCase()
  const scheme = rawScheme === 'https' ? 'https' : 'http'
  const host = formatListenHost(lanListenHost(input) || '127.0.0.1')
  const port = lanListenPort(input)
  const omit = (scheme === 'http' && port === 80) || (scheme === 'https' && port === 443)
  return omit ? `${scheme}://${host}` : `${scheme}://${host}:${port}`
}

export function lanOpenAIBaseURL(input: InferenceHowToInput): string {
  return `${lanOrigin(input)}${OPENAI_V1_SUFFIX}`
}

export function lanCompletionsURL(input: InferenceHowToInput): string {
  return `${lanOrigin(input)}${CHAT_COMPLETIONS_PATH}`
}

export function inferenceAPIKey(grantPlaintext?: string | null): string {
  const trimmed = (grantPlaintext ?? '').trim()
  return trimmed || MISSING_INFERENCE_KEY
}

export function inferenceCurl(completionsURL: string, apiKey: string): string {
  return [
    `curl ${completionsURL} \\`,
    `  -H 'Authorization: Bearer ${apiKey}' \\`,
    `  -H 'Content-Type: application/json' \\`,
    `  -d '{"model":"llama3","messages":[{"role":"user","content":"Hello"}]}'`,
  ].join('\n')
}

export function inferenceEnv(baseURL: string, apiKey: string): string {
  return `export OPENAI_BASE_URL='${baseURL}'\nexport OPENAI_API_KEY='${apiKey}'`
}

export function inferenceHowTo(input: InferenceHowToInput): InferenceHowTo {
  const apiKey = inferenceAPIKey(input.grantPlaintext)
  const lanBase = lanOpenAIBaseURL(input)
  const lanCompletions = lanCompletionsURL(input)
  return {
    lanBaseURL: lanBase,
    lanCompletionsURL: lanCompletions,
    apiKey,
    curl: inferenceCurl(lanCompletions, apiKey),
    env: inferenceEnv(lanBase, apiKey),
    cageBaseURL: CAGE_OPENAI_BASE_URL,
    cageEnv: inferenceEnv(CAGE_OPENAI_BASE_URL, apiKey),
    cageDnsLine: CAGE_DNS_LINE,
  }
}

export function inferenceHowToFromOrigin(
  origin: string,
  extra: {
    role?: InferenceHostRole
    memberHost?: string | null
    advertiseHost?: string | null
    tailnetHost?: string | null
    grantPlaintext?: string | null
  } = {},
): InferenceHowTo {
  let host = '127.0.0.1'
  let port: number | null = HOME_LISTEN_PORT
  let scheme = 'http'
  try {
    const url = new URL(origin)
    if (url.hostname) host = url.hostname
    scheme = url.protocol.replace(':', '') || 'http'
    port = url.port ? Number(url.port) : HOME_LISTEN_PORT
  } catch {
    // Keep BarkVisor listen defaults.
  }
  return inferenceHowTo({
    role: extra.role ?? 'self',
    originHost: host,
    originPort: port,
    originScheme: scheme,
    memberHost: extra.memberHost,
    advertiseHost: extra.advertiseHost,
    tailnetHost: extra.tailnetHost,
    grantPlaintext: extra.grantPlaintext,
  })
}
