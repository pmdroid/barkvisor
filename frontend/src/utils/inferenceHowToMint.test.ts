import { describe, expect, test } from 'bun:test'
import {
  INFERENCE_HOWTO_AUTO_NAME,
  INFERENCE_HOWTO_KIND,
  INFERENCE_HOWTO_SIGN_IN,
  inferenceHowToMintBanner,
  inferenceHowToMintBody,
  needsInferenceHowToMint,
} from './inferenceHowToMint'

describe('inferenceHowToMint (#225)', () => {
  test('mints inference kind when the session has no inference key', () => {
    const body = inferenceHowToMintBody()
    expect(body.kind).toBe(INFERENCE_HOWTO_KIND)
    expect(body.name).toBe(INFERENCE_HOWTO_AUTO_NAME)
    expect(needsInferenceHowToMint([])).toBe(true)
    expect(needsInferenceHowToMint([{ kind: 'full' }])).toBe(true)
    expect(needsInferenceHowToMint([{ kind: 'inference' }])).toBe(false)
    expect(needsInferenceHowToMint([{ kind: 'full' }, { kind: 'inference' }])).toBe(false)
  })

  test('auth failure banners sign-in; 403 is not a role-admin path', () => {
    expect(inferenceHowToMintBanner({ status: 401, message: 'expired' })).toBe(INFERENCE_HOWTO_SIGN_IN)
    expect(inferenceHowToMintBanner({ status: 403, message: 'forbidden' })).toBe('forbidden')
    expect(inferenceHowToMintBanner({ status: 403, message: 'forbidden' })).not.toBe(
      'API keys are admin-only.',
    )
    expect(inferenceHowToMintBanner({ status: 500, message: 'boom' })).toBe('boom')
  })
})
