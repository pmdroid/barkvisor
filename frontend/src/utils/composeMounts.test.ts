import { describe, expect, test } from 'bun:test'
import { mountsFromSharedPaths, parseComposeMounts, visibleAppMounts } from './composeMounts'

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

describe('visibleAppMounts', () => {
  test('prefers compose mounts over sharedPaths', () => {
    expect(visibleAppMounts({
      compose: '    volumes:\n      - /compose:/app\n',
      sharedPaths: ['/shared:/app'],
    })).toEqual([
      { kind: 'bind', source: '/compose', target: '/app', readOnly: false },
    ])
    expect(visibleAppMounts({
      compose: '',
      sharedPaths: ['/shared:/app'],
    })).toEqual([
      { kind: 'bind', source: '/shared', target: '/app', readOnly: false },
    ])
  })
})
