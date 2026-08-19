import { describe, expect, test } from 'bun:test'
import { loginOfferSvg } from './qrSvg'

describe('login offer QR', () => {
  test('encodes a login URI as SVG', async () => {
    const uri = 'barkvisor://login/v1?code=ABCD-EFGH&host=192.168.0.8&port=7777'
    const svg = await loginOfferSvg(uri)
    expect(svg).toContain('<svg')
    expect(svg).not.toContain('barkvisor://pair/v1')
  })
})
