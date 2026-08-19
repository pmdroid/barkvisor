import { describe, expect, test } from 'bun:test'
import { pairingQrSvg } from './pairingQr'

const lanOffer =
  'barkvisor://pair/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777&agentPort=9123&hostId=h1&fp=abc'
const dnsOffer =
  'barkvisor://pair/v1?code=WXYZ-1234&host=box.tailnet.ts.net&port=7777&agentPort=9123&hostId=h1&fp=abc'

describe('pairing QR', () => {
  test('encodes the current barkvisor:// offer as an SVG QR', () => {
    const svg = pairingQrSvg(`  ${lanOffer}  `)
    expect(svg).toBeTruthy()
    expect(svg!.startsWith('<svg')).toBe(true)
    expect(svg).toContain('viewBox')
    expect(svg).toContain('#111111')
    expect(svg).toContain('#ffffff')
  })

  test('re-encoding a new address produces a different QR', () => {
    const lan = pairingQrSvg(lanOffer)
    const dns = pairingQrSvg(dnsOffer)
    expect(lan).not.toBe(dns)
    expect(pairingQrSvg(lanOffer)).toBe(lan)
  })

  test('hides when there is no payload to encode', () => {
    expect(pairingQrSvg('')).toBeNull()
    expect(pairingQrSvg('   ')).toBeNull()
  })
})
