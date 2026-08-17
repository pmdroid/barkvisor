import { describe, expect, test } from 'bun:test'
import { authorizedKeyForCloudInit, HOME_SSH_KEYS_PATH } from './homeSSHKey'

describe('homeSSHKey (PAS-217)', () => {
  test('Home keys are listed on This Device, not a worker path', () => {
    expect(HOME_SSH_KEYS_PATH).toBe('/ssh-keys')
    expect(HOME_SSH_KEYS_PATH).not.toContain('/home/devices/')
  })

  test('cloud-init line is public key text plus Home name, not a key id', () => {
    expect(authorizedKeyForCloudInit({
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk',
      name: 'laptop',
    })).toBe('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk laptop')
  })

  test('does not duplicate a name that is already the key comment', () => {
    expect(authorizedKeyForCloudInit({
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk laptop',
      name: 'laptop',
    })).toBe('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk laptop')
  })

  test('omits an empty name', () => {
    expect(authorizedKeyForCloudInit({
      publicKey: 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk',
      name: '  ',
    })).toBe('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGk')
  })
})
