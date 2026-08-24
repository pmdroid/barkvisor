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
  grantPlaintext?: string | null
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

export function lanListenHost(input: InferenceHowToInput): string {
  if (input.role === 'member') {
    const member = stripListenHost(input.memberHost ?? '')
    if (member) return member
  }
  return stripListenHost(input.originHost)
}

export function lanListenPort(input: InferenceHowToInput): number {
  if (input.role === 'member' && stripListenHost(input.memberHost ?? '')) {
    return HOME_LISTEN_PORT
  }
  const port = input.originPort
  if (port && port > 0) return port
  return HOME_LISTEN_PORT
}

export function lanOrigin(input: InferenceHowToInput): string {
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
    grantPlaintext: extra.grantPlaintext,
  })
}
