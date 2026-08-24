import { describe, expect, test } from 'bun:test'
import {
  ONYX_OLLAMA_API_BASE,
  ONYX_RELEASE_TAG,
  ONYX_SLUGS,
  isOnyxImage,
  mergeOnyxUserData,
  onyxUserData,
} from './onyxImage'

describe('onyxImage', () => {
  test('one image family: slugs for arm64 and x86_64', () => {
    expect(ONYX_SLUGS).toEqual(['onyx', 'onyx-arm64', 'onyx-x86_64'])
    expect(isOnyxImage({ name: 'Onyx', slug: 'onyx' })).toBe(true)
    expect(isOnyxImage({ name: 'Onyx', slug: 'onyx-arm64' })).toBe(true)
    expect(isOnyxImage({ name: 'Ubuntu 24.04 LTS', slug: 'ubuntu-24.04-arm64' })).toBe(false)
    expect(isOnyxImage({ name: 'my onyx lab' })).toBe(false)
    expect(isOnyxImage({ name: 'Onyx', slug: 'ubuntu-24.04-arm64' })).toBe(false)
    expect(isOnyxImage({ name: 'Coding Agent' })).toBe(false)
  })

  test('user-data installs Onyx Lite and cage Ollama, not JWT', () => {
    const yaml = onyxUserData()
    expect(yaml).toContain('docker-compose.onyx-lite.yml')
    expect(yaml).toContain(ONYX_RELEASE_TAG)
    expect(yaml).toContain(ONYX_OLLAMA_API_BASE)
    expect(yaml).toContain('barkvisor_allow_host_ollama: true')
    expect(yaml).not.toContain('10.0.2.2:11434/v1')
    expect(yaml).not.toContain(':7777')
    expect(yaml).not.toContain('Authorization: Bearer')
    expect(yaml).not.toContain('OPENAI_API_KEY=')
    expect(mergeOnyxUserData('packages:\n  - vim\n', { name: 'Onyx', slug: 'onyx-arm64' })).toContain(
      'vim',
    )
    expect(mergeOnyxUserData('', { name: 'Onyx', slug: 'onyx-arm64' })).toContain(
      'docker-compose.onyx-lite.yml',
    )
    expect(mergeOnyxUserData('', { name: 'Ubuntu' })).toBe('')
  })
})
