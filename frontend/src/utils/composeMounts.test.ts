import { describe, expect, test } from 'bun:test'
import {
  isManagedAppMount,
  isUnderManagedRoot,
  mountsFromSharedPaths,
  parseComposeMounts,
  visibleAppMounts,
} from './composeMounts'

describe('parseComposeMounts', () => {
  test('parses bind and named volume lines', () => {
    const yaml = `
services:
  plex:
    volumes:
      - /media/movies:/data/movies
      - plex-config:/config
`
    const mounts = parseComposeMounts(yaml)
    expect(mounts).toEqual([
      { kind: 'bind', source: '/media/movies', target: '/data/movies', readOnly: false },
      { kind: 'volume', source: 'plex-config', target: '/config', readOnly: false },
    ])
  })

  test('marks :ro binds read-only', () => {
    const mounts = parseComposeMounts('      - /media:/media:ro\n')
    expect(mounts).toEqual([
      { kind: 'bind', source: '/media', target: '/media', readOnly: true },
    ])
  })
})

describe('mountsFromSharedPaths', () => {
  test('splits host:guest binds', () => {
    expect(mountsFromSharedPaths(['/media/movies:/movies', 'plex-config:/config'])).toEqual([
      { kind: 'bind', source: '/media/movies', target: '/movies', readOnly: false },
      { kind: 'volume', source: 'plex-config', target: '/config', readOnly: false },
    ])
    expect(mountsFromSharedPaths(['/media:/media:ro'])).toEqual([
      { kind: 'bind', source: '/media', target: '/media', readOnly: true },
    ])
  })
})

describe('isManagedAppMount', () => {
  const root = '/var/lib/barkvisor/apps/whoami'
  const roots = [root, `${root}/volumes`, `${root}/volumes/config`]

  test('protects an exact volume-root bind', () => {
    expect(isUnderManagedRoot(root, root)).toBe(true)
    expect(isUnderManagedRoot(`${root}/`, root)).toBe(true)
    expect(isManagedAppMount(
      { kind: 'bind', source: root, target: '/data', readOnly: false },
      roots,
    )).toBe(true)
    expect(isManagedAppMount(
      { kind: 'bind', source: `${root}/`, target: '/data', readOnly: false },
      [`${root}/`],
    )).toBe(true)
  })

  test('protects children without treating a sibling prefix as managed', () => {
    expect(isManagedAppMount(
      { kind: 'bind', source: `${root}/volumes/config`, target: '/config', readOnly: false },
      roots,
    )).toBe(true)
    expect(isManagedAppMount(
      { kind: 'bind', source: `${root}-extra`, target: '/x', readOnly: false },
      roots,
    )).toBe(false)
    expect(isManagedAppMount(
      { kind: 'bind', source: '/media/movies', target: '/movies', readOnly: false },
      roots,
    )).toBe(false)
  })

  test('locks named volumes regardless of roots', () => {
    expect(isManagedAppMount(
      { kind: 'volume', source: 'plex-config', target: '/config', readOnly: false },
      [],
    )).toBe(true)
  })
})

describe('visibleAppMounts', () => {
  test('keeps sharedPaths binds after compose gains a volume', () => {
    expect(visibleAppMounts({
      compose: '    volumes:\n      - /compose:/app\n',
      sharedPaths: ['/shared:/app', '/compose:/app'],
    })).toEqual([
      { kind: 'bind', source: '/compose', target: '/app', readOnly: false },
      { kind: 'bind', source: '/shared', target: '/app', readOnly: false },
    ])
    expect(visibleAppMounts({
      compose: '',
      sharedPaths: ['/shared:/app'],
    })).toEqual([
      { kind: 'bind', source: '/shared', target: '/app', readOnly: false },
    ])
  })
})
