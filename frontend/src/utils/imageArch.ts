/**
 * Image / ISO architecture helpers for upload & download forms.
 * API arch labels: `arm64` | `x86_64` (not "amd64").
 */

export type ImageArch = 'arm64' | 'x86_64'

export type ArchDetectResult = {
  arch: ImageArch | null
  /** Human-readable token that matched (e.g. "x86_64", "aarch64"). */
  matched?: string
}

/**
 * Detect guest arch from a filename, URL path, or free-form label.
 * Covers common patterns from popular distros and cloud images.
 *
 * x86_64 examples:
 *   Fedora-KDE-Desktop-Live-44-1.7.x86_64.iso
 *   ubuntu-24.04.1-live-server-amd64.iso
 *   debian-12.7.0-amd64-netinst.iso
 *   Rocky-9.4-x86_64-minimal.iso
 *   openSUSE-Leap-15.6-DVD-x86_64.iso
 *   archlinux-2024.07.01-x86_64.iso
 *   alpine-standard-3.20.0-x86_64.iso
 *   Win11_English_x64.iso
 *
 * arm64 examples:
 *   ubuntu-24.04-live-server-arm64.iso
 *   Fedora-Server-dvd-aarch64-40.iso
 *   debian-12.0.0-arm64-netinst.iso
 *   alpine-virt-3.20.0-aarch64.iso
 *   rhel-9.4-aarch64-dvd.iso
 */
export function detectImageArch(input: string | null | undefined): ArchDetectResult {
  if (!input || !input.trim()) return { arch: null }

  // Match against full URL path (distros often put arch in a parent segment)
  // and the basename (Fedora/Ubuntu put arch in the filename).
  let raw = input.trim()
  let path = raw
  try {
    if (/^https?:\/\//i.test(raw)) {
      const u = new URL(raw)
      path = u.pathname || raw
    }
  } catch {
    /* keep raw */
  }
  path = path.split(/[?#]/)[0] ?? path
  const basename = path.split(/[/\\]/).pop() ?? path
  // Normalize: treat _ and spaces like - for token boundaries
  const haystack = `${path} ${basename}`.toLowerCase().replace(/[_\s]+/g, '-')

  // --- Explicit x86_64 family ---
  const x86Patterns: Array<{ re: RegExp; token: string }> = [
    { re: /x86[_-]?64/i, token: 'x86_64' },
    { re: /amd64/i, token: 'amd64' },
    { re: /(^|[^a-z0-9])x64([^a-z0-9]|$)/i, token: 'x64' },
    { re: /intel64/i, token: 'intel64' },
  ]

  // --- Explicit arm64 / aarch64 (not armhf/armel) ---
  const armPatterns: Array<{ re: RegExp; token: string }> = [
    { re: /aarch64/i, token: 'aarch64' },
    { re: /arm64/i, token: 'arm64' },
    { re: /armv8/i, token: 'armv8' },
  ]

  // Prefer the rightmost architecture token (filename usually wins over /pool/main/…/amd64/… noise).
  type Hit = { arch: ImageArch; token: string; index: number }
  const hits: Hit[] = []

  for (const { re, token } of x86Patterns) {
    let m: RegExpExecArray | null
    const r = new RegExp(re.source, re.flags.includes('g') ? re.flags : `${re.flags}g`)
    while ((m = r.exec(haystack)) !== null) {
      hits.push({ arch: 'x86_64', token, index: m.index })
    }
  }
  for (const { re, token } of armPatterns) {
    let m: RegExpExecArray | null
    const r = new RegExp(re.source, re.flags.includes('g') ? re.flags : `${re.flags}g`)
    while ((m = r.exec(haystack)) !== null) {
      hits.push({ arch: 'arm64', token, index: m.index })
    }
  }

  if (hits.length > 0) {
    hits.sort((a, b) => b.index - a.index)
    const best = hits[0]
    return { arch: best.arch, matched: best.token }
  }

  // Distro-specific fallbacks without explicit arch tokens
  if (/\b(raspios|raspberry-?pi|rpi)\b/i.test(haystack)) {
    return { arch: 'arm64', matched: 'raspberry-pi' }
  }

  return { arch: null }
}

/**
 * Strict normalize of free-form image/catalog arch labels.
 * Returns null for unknown values (unlike hostArchToImageArch, which defaults).
 */
export function normalizeImageArch(arch: string | null | undefined): ImageArch | null {
  if (!arch || !String(arch).trim()) return null
  const h = String(arch).toLowerCase().trim()
  if (h === 'x86_64' || h === 'amd64' || h === 'x64') return 'x86_64'
  if (h === 'arm64' || h === 'aarch64') return 'arm64'
  return null
}

/** Normalize host capability arch to an ImageArch when possible. */
export function hostArchToImageArch(hostArch: string | null | undefined): ImageArch {
  const strict = normalizeImageArch(hostArch)
  if (strict) return strict
  // Unknown → arm64 (historical BarkVisor default on Apple Silicon)
  return 'arm64'
}

/**
 * Image arches this host can run natively (PAS-48 / PAS-37).
 * Host arch only — do not expand from guestTypes (static dual-arch lists
 * historically made catalog filters a no-op). Unknown/empty host → empty set
 * (fail-closed; do not invent arm64).
 */
export function runnableImageArches(hostArch: string | null | undefined): Set<ImageArch> {
  const host = normalizeImageArch(hostArch)
  return host ? new Set([host]) : new Set()
}

/**
 * Whether a catalog/local image arch is runnable on this host.
 * Unknown image arches and unknown hosts are unsupported (never coerce to arm64).
 */
export function imageArchSupportedOnHost(
  imageArch: string | null | undefined,
  hostArch: string | null | undefined,
): boolean {
  const img = normalizeImageArch(imageArch)
  const host = normalizeImageArch(hostArch)
  if (!img || !host) return false
  return img === host
}

/**
 * Choose arch for a form: filename/URL detection first, else host default.
 */
export function resolveImageArch(
  filenameOrUrl: string | null | undefined,
  hostArch?: string | null,
): ImageArch {
  const detected = detectImageArch(filenameOrUrl)
  if (detected.arch) return detected.arch
  return hostArchToImageArch(hostArch)
}
