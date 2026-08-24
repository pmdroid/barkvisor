/** Auto-mint an inference key when the Ollama howto card opens (GitHub #225). */

export const INFERENCE_HOWTO_AUTO_NAME = 'Ollama howto (auto)'
export const INFERENCE_HOWTO_KIND = 'inference'
export const INFERENCE_HOWTO_EXPIRES_IN = '90d'
export const INFERENCE_HOWTO_SIGN_IN = 'Sign in required'

export type InferenceHowToKeyRow = {
  kind?: string | null
}

export function hasInferenceKey(keys: InferenceHowToKeyRow[]): boolean {
  return keys.some((key) => key.kind === INFERENCE_HOWTO_KIND)
}

export function needsInferenceHowToMint(keys: InferenceHowToKeyRow[]): boolean {
  return !hasInferenceKey(keys)
}

export function inferenceHowToMintBody(): {
  name: string
  expiresIn: string
  kind: string
} {
  return {
    name: INFERENCE_HOWTO_AUTO_NAME,
    expiresIn: INFERENCE_HOWTO_EXPIRES_IN,
    kind: INFERENCE_HOWTO_KIND,
  }
}

/** Session/auth failure copy. 403 is not treated as "not admin". */
export function inferenceHowToMintBanner(input: {
  status?: number | null
  message?: string | null
}): string {
  if (input.status === 401) return INFERENCE_HOWTO_SIGN_IN
  const message = (input.message ?? '').trim()
  return message || 'Could not mint an inference key'
}
