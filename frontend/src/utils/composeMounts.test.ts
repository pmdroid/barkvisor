import { describe, expect, it } from 'vitest'
import { mountsFromSharedPaths, parseComposeMounts } from './composeMounts'

describe('parseComposeMounts', () => {
  it('parses bind and named volume lines', () => {
    const yaml = `
services:
  plex:
    volumes:
      - /media/movies:/data/movies
      - plex-config:/config
`
    const mounts = parseComposeMounts(yaml)
    expect(mounts).toEqual([
      { kind: 'bind', source: '/media/movies', target: '/data/movies' },
      { kind: 'volume', source: 'plex-config', target: '/config' },
    ])
  })
})

describe('mountsFromSharedPaths', () => {
  it('splits host:guest binds', () => {
    expect(mountsFromSharedPaths(['/media/movies:/movies', 'plex-config:/config'])).toEqual([
      { kind: 'bind', source: '/media/movies', target: '/movies' },
      { kind: 'volume', source: 'plex-config', target: '/config' },
    ])
  })
})
