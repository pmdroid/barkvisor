/** Install copy matching OllamaDetect.installHint. Do not invent a second glossary. */

export const OLLAMA_MAC_INSTALL_HINT = 'Install Ollama with Homebrew: brew install ollama'
export const OLLAMA_LINUX_INSTALL_HINT =
  'Ollama is optional. Install the distro package or see https://ollama.com/download'
export const OLLAMA_DOWNLOAD_HREF = 'https://ollama.com/download'
export const OLLAMA_MAC_INSTALL_COMMAND = 'brew install ollama'
export const OLLAMA_MAC_START_COMMAND = 'brew services start ollama'

export type OllamaInstallStep = {
  title: string
  command?: string
  href?: string
}

/** Same as OllamaDetect.installHint: Linux vs everything else (macOS). */
export function ollamaInstallHint(os: string): string {
  return os.trim().toLowerCase() === 'linux' ? OLLAMA_LINUX_INSTALL_HINT : OLLAMA_MAC_INSTALL_HINT
}

export function ollamaInstallOs(os?: string | null, installHint?: string | null): string {
  const normalized = (os ?? '').trim().toLowerCase()
  if (normalized === 'linux') return 'linux'
  if (normalized === 'macos' || normalized === 'darwin' || normalized === 'mac') return 'macos'
  const hint = (installHint ?? '').toLowerCase()
  if (hint.includes('distro') || hint.includes('ollama.com/download')) return 'linux'
  return 'macos'
}

/** Prefer catalog Device hints, then platform, then both so mixed Homes still see commands. */
export function ollamaInstallOses(input: {
  installHints?: readonly (string | null | undefined)[]
  platformOs?: string | null
}): string[] {
  const found = new Set<string>()
  for (const hint of input.installHints ?? []) {
    if (hint?.trim()) found.add(ollamaInstallOs(undefined, hint))
  }
  if (found.size === 0 && input.platformOs?.trim()) {
    found.add(ollamaInstallOs(input.platformOs))
  }
  if (found.size === 0) return ['macos', 'linux']
  return ['macos', 'linux'].filter((os) => found.has(os))
}

export function ollamaInstallSteps(os: string): OllamaInstallStep[] {
  if (os.trim().toLowerCase() === 'linux') {
    return [
      {
        title: OLLAMA_LINUX_INSTALL_HINT,
        href: OLLAMA_DOWNLOAD_HREF,
      },
    ]
  }
  return [
    {
      title: OLLAMA_MAC_INSTALL_HINT,
      command: OLLAMA_MAC_INSTALL_COMMAND,
    },
    {
      title: 'Start Ollama',
      command: OLLAMA_MAC_START_COMMAND,
    },
  ]
}

export function ollamaCatalogInstallHint(
  devices: readonly { installHint?: string | null }[],
  os: string,
): string {
  for (const row of devices) {
    const hint = row.installHint?.trim()
    if (hint) return hint
  }
  return ollamaInstallHint(os)
}

export function ollamaInstallOsLabel(os: string): string {
  return os.trim().toLowerCase() === 'linux' ? 'Linux' : 'macOS'
}

/** Hide until a catalog fetch finished. First paint is loading=false and catalog=null. */
export function shouldShowOllamaInstall(input: {
  loading: boolean
  catalog: unknown | null
  anyReachable: boolean
}): boolean {
  if (input.loading || input.catalog == null) return false
  return !input.anyReachable
}
