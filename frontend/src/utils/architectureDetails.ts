/** localStorage key for “always show architecture details” (PAS-93). */
export const ALWAYS_SHOW_ARCH_DETAILS_KEY = 'barkvisor.alwaysShowArchitectureDetails'

export function readAlwaysShowArchitectureDetails(): boolean {
  try {
    return localStorage.getItem(ALWAYS_SHOW_ARCH_DETAILS_KEY) === '1'
  } catch {
    return false
  }
}

export function writeAlwaysShowArchitectureDetails(on: boolean): void {
  try {
    localStorage.setItem(ALWAYS_SHOW_ARCH_DETAILS_KEY, on ? '1' : '0')
  } catch {
    // Private mode / blocked storage — treat as session-only.
  }
}

/**
 * Arch is a problem (PAS-48) when the chosen guest arch is not host-runnable.
 * Unknown / empty values are not treated as a problem — the create path
 * still fail-closes elsewhere until hostArch is known.
 */
export function architectureIsProblem(
  guestArch: string | null | undefined,
  hostRunnable: boolean,
): boolean {
  if (!guestArch) return false
  return !hostRunnable
}

/** Reveal Architecture / firmware / TPM on the summary (PAS-93). */
export function shouldRevealArchitectureDetails(opts: {
  alwaysShow: boolean
  customized: boolean
  problem: boolean
}): boolean {
  return opts.alwaysShow || opts.customized || opts.problem
}

/** Human label for API/host arch tokens. */
export function architectureLabel(arch: string | null | undefined): string {
  if (arch === 'x86_64' || arch === 'amd64') return 'x86_64'
  if (arch === 'arm64' || arch === 'aarch64') return 'ARM64'
  return arch || 'host default'
}

/** QEMU machine implied by a guest type / arch (inspect-only). */
export function defaultMachineType(vmTypeOrArch: string | null | undefined): string {
  const raw = vmTypeOrArch ?? ''
  if (raw.includes('amd64') || raw.includes('x86')) return 'q35'
  return 'virt'
}
