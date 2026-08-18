import type { SSHKey } from '../api/types'

/** Home SSH public keys. This Device GET /ssh-keys — never a worker table. */
export const HOME_SSH_KEYS_PATH = '/ssh-keys'

/**
 * Cloud-init authorized_keys line: public key text plus the Home name as comment.
 * Does not send a worker-local key id.
 */
export function authorizedKeyForCloudInit(key: Pick<SSHKey, 'publicKey' | 'name'>): string {
  const text = key.publicKey.replace(/[\r\n\x00-\x1f\x7f]+/g, ' ').trim()
  const name = key.name.replace(/[\r\n\x00-\x1f\x7f]+/g, ' ').trim()
  if (!name) return text
  const parts = text.split(/\s+/)
  if (parts.length >= 3 && parts.slice(2).join(' ') === name) return text
  return `${text} ${name}`
}
