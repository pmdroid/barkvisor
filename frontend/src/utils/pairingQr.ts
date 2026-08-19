import { renderSVG } from 'uqr'

const pairingQrOptions = {
  ecc: 'M' as const,
  boostEcc: true,
  border: 4,
  pixelSize: 1,
  whiteColor: '#ffffff',
  blackColor: '#111111',
}

/** SVG QR of a pairing URI. Empty or unencodable payloads return null. */
export function pairingQrSvg(payload: string): string | null {
  const text = payload.trim()
  if (!text) return null
  try {
    return renderSVG(text, pairingQrOptions)
  } catch {
    return null
  }
}
