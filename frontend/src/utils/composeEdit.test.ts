import { describe, expect, test } from 'bun:test'
import { parseComposeMounts } from './composeMounts'
import {
  addComposeMount,
  afterRemoveSharedPaths,
  appPortEditorRows,
  applyAppVolumeChange,
  applyComposeDocumentDrafts,
  composeBindFromDraft,
  composeMountFromDraft,
  ensureApplicationSharedPaths,
  extractApplicationSharedPaths,
  extractComposeBlock,
  mergeApplicationSharedPaths,
  parseComposeMountSlots,
  parseComposePortSlots,
  parseComposePorts,
  removeComposeMount,
  replaceComposeBlock,
  retainUsedPaths,
  setComposeMounts,
  setComposePorts,
} from './composeEdit'

const base = `services:
  whoami:
    image: traefik/whoami
    ports:
      - "8080:80"
      - "9090:90/udp"
    volumes:
      - "/data/config:/config"
    restart: unless-stopped
`

describe('composeEdit', () => {
  test('applyAppVolumeChange edits sharedPaths when compose is absent', () => {
    const added = applyAppVolumeChange(null, ['/keep'], {
      type: 'add',
      mount: { source: '/media', target: '/media', readOnly: false },
    })
    expect(added.compose).toBeNull()
    expect(added.sharedPaths).toEqual(['/keep', '/media:/media'])
    const ro = applyAppVolumeChange(null, [], {
      type: 'add',
      mount: { source: '/data/host', target: '/container/data', readOnly: true },
    })
    expect(ro.sharedPaths).toEqual(['/data/host:/container/data:ro'])
    const removed = applyAppVolumeChange(null, ['/keep', '/media:/media'], {
      type: 'remove',
      mount: { source: '/media', target: '/media', readOnly: false },
    })
    expect(removed.compose).toBeNull()
    expect(removed.sharedPaths).toEqual(['/keep'])
  })

  test('appPortEditorRows prefers compose and does not duplicate live host ports', () => {
    const parsed = [
      { hostPort: 8080, containerPort: 80, proto: 'tcp', hostIP: '127.0.0.1' },
    ]
    const live = [
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
      { hostPort: 8080, containerPort: 8080, proto: 'tcp' },
    ]
    expect(appPortEditorRows(parsed, live)).toEqual(parsed)
    expect(appPortEditorRows([], live)).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
      { hostPort: 8080, containerPort: 8080, proto: 'tcp' },
    ])
  })

  test('parseComposePorts reads quoted and plain entries with protocols', () => {
    expect(parseComposePorts(base)).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
      { hostPort: 9090, containerPort: 90, proto: 'udp' },
    ])
    expect(parseComposePorts('ports:\n    - 8080:80\n    - 443:443/udp')).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
      { hostPort: 443, containerPort: 443, proto: 'udp' },
    ])
    expect(parseComposePorts('ports:\n  - "80"')).toEqual([
      { hostPort: 80, containerPort: 80, proto: 'tcp' },
    ])
    expect(parseComposePorts('ports:\n  - "0:80"\n  - "80:0"\n  - "80:70000"\n  - foo:bar')).toEqual([])
    expect(parseComposePorts('environment:\n  - "9090:90"')).toEqual([])
    expect(parseComposePorts('ports:\n  - "127.0.0.1:8080:80"\n  - 0.0.0.0:5353:5353/udp')).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp', hostIP: '127.0.0.1' },
      { hostPort: 5353, containerPort: 5353, proto: 'udp', hostIP: '0.0.0.0' },
    ])
    expect(parseComposePorts('ports:\n  - "[::1]:8080:80"')).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp', hostIP: '::1' },
    ])
  })

  test('parseComposePorts reads long-form port objects', () => {
    const yaml = `services:
  a:
    image: img
    ports:
      - target: 80
        published: 8080
        protocol: tcp
        host_ip: 127.0.0.1
      - { target: 53, published: 5353, protocol: udp, host_ip: 0.0.0.0 }
`
    expect(parseComposePorts(yaml)).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp', hostIP: '127.0.0.1' },
      { hostPort: 5353, containerPort: 53, proto: 'udp', hostIP: '0.0.0.0' },
    ])
  })

  test('setComposePorts keeps a deleted first-service row out of later services', () => {
    const yaml = `services:
  a:
    image: img-a
    ports:
      - "111:111"
  b:
    image: img-b
    ports:
      - "222:222"
`
    const slots = parseComposePortSlots(yaml).filter((row) => row.hostPort !== 111)
    const next = setComposePorts(yaml, slots)
    expect(next).not.toContain('111')
    expect(next).toContain('  a:\n    image: img-a\n  b:')
    expect(next).toContain('  b:\n    image: img-b\n    ports:\n      - "222:222"')
    expect(parseComposePorts(next)).toEqual([
      { hostPort: 222, containerPort: 222, proto: 'tcp' },
    ])
  })

  test('setComposePorts keeps IP-bound mappings and leaves unknown rows', () => {
    const yaml = `services:
  a:
    image: img
    ports:
      - "127.0.0.1:8080:80"
      - "0.0.0.0:5353:5353/udp"
      - "not-a-port"
`
    const rewritten = setComposePorts(yaml, parseComposePorts(yaml))
    expect(rewritten).toContain('"127.0.0.1:8080:80"')
    expect(rewritten).toContain('"0.0.0.0:5353:5353/udp"')
    expect(rewritten).toContain('not-a-port')
    const emptied = setComposePorts(yaml, [])
    expect(emptied).toContain('not-a-port')
    expect(emptied).not.toContain('8080')
    expect(emptied).not.toContain('5353')
  })

  test('setComposePorts rewrites long-form objects without leaving orphans', () => {
    const yaml = `services:
  a:
    image: img
    ports:
      - target: 80
        published: 8080
        protocol: tcp
        host_ip: 127.0.0.1
    restart: unless-stopped
`
    const next = setComposePorts(yaml, parseComposePorts(yaml))
    expect(next).toContain('"127.0.0.1:8080:80"')
    expect(next).not.toContain('target:')
    expect(next).not.toContain('published:')
    expect(next).toContain('restart: unless-stopped')
  })

  test('parseComposePorts reads ports blocks and ignores env-like siblings', () => {
    const yaml = `services:
  whoami:
    image: traefik/whoami
    ports:
      - "8080:80"
    environment:
      - "9090:90"
`
    expect(parseComposePorts(yaml)).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
    ])
  })

  test('setComposePorts replaces rows in place and keeps formatting', () => {
    const next = setComposePorts(base, [
      { hostPort: 8081, containerPort: 80, proto: 'tcp' },
      { hostPort: 9091, containerPort: 90, proto: 'udp' },
    ])
    expect(next).toContain('      - "8081:80"')
    expect(next).toContain('      - "9091:90/udp"')
    expect(next).not.toContain('8080')
    expect(next).toContain('restart: unless-stopped')
  })

  test('setComposePorts appends extras to the last block and drops removed rows', () => {
    const next = setComposePorts(base, [{ hostPort: 7070, containerPort: 70, proto: 'tcp' }])
    expect(parseComposePorts(next)).toEqual([
      { hostPort: 7070, containerPort: 70, proto: 'tcp' },
    ])
    expect(next).not.toContain('9090')
    const twoServices = `services:
  a:
    image: img-a
    ports:
      - "111:111"
  b:
    image: img-b
    ports:
      - "222:222"
`
    const grown = setComposePorts(twoServices, [
      { hostPort: 111, containerPort: 111, proto: 'tcp' },
      { hostPort: 222, containerPort: 222, proto: 'tcp' },
      { hostPort: 333, containerPort: 333, proto: 'udp' },
    ])
    expect(grown.match(/- "111:111"/g)?.length).toBe(1)
    expect(grown).toContain('  b:\n    image: img-b\n    ports:\n      - "222:222"\n      - "333:333/udp"')
    expect(parseComposePorts(grown).length).toBe(3)
  })

  test('setComposePorts removes the ports key when emptied and inserts when missing', () => {
    const emptied = setComposePorts(base, [])
    expect(emptied).not.toContain('ports:')
    expect(emptied).toContain('image: traefik/whoami')
    expect(emptied).toContain('volumes:')
    const noPorts = `services:
  whoami:
    image: traefik/whoami
    restart: unless-stopped
`
    const added = setComposePorts(noPorts, [{ hostPort: 8080, containerPort: 80, proto: 'tcp' }])
    expect(added).toContain('    ports:\n      - "8080:80"')
    expect(parseComposePorts(added)).toEqual([
      { hostPort: 8080, containerPort: 80, proto: 'tcp' },
    ])
    expect(setComposePorts(noPorts, [])).toBe(noPorts)
  })

  test('setComposePorts rewrites flow-style ports', () => {
    const flow = `services:
  a:
    image: img
    ports: []
`
    const added = setComposePorts(flow, [{ hostPort: 99, containerPort: 99, proto: 'tcp' }])
    expect(added).toContain('    ports:\n      - "99:99"')
    expect(added).not.toContain('ports: []')
  })

  test('addComposeMount appends to the last volumes block', () => {
    const yaml = `services:
  a:
    image: img-a
    volumes:
      - "/a:/a"
  b:
    image: img-b
    volumes:
      - "/b:/b"
`
    const next = addComposeMount(yaml, { source: '/media', target: '/media', readOnly: false })
    expect(next).toContain('  a:\n    image: img-a\n    volumes:\n      - "/a:/a"')
    expect(next).toContain('  b:\n    image: img-b\n    volumes:\n      - "/b:/b"\n      - "/media:/media"')
  })

  test('addComposeMount appends to an existing block and dedupes', () => {
    const next = addComposeMount(base, { source: '/data/media', target: '/media', readOnly: true })
    expect(next).toContain('      - "/data/media:/media:ro"')
    expect(next).toContain('"/data/config:/config"')
    expect(addComposeMount(next, { source: '/data/media', target: '/media', readOnly: true })).toBe(next)
    expect(addComposeMount(base, { source: '/data/config', target: '/config', readOnly: false }))
      .toBe(base)
  })

  test('addComposeMount creates the volumes key after image', () => {
    const noVolumes = `services:
  whoami:
    image: traefik/whoami
    ports:
      - "8080:80"
`
    const next = addComposeMount(noVolumes, { source: '/srv/ds', target: '/ds', readOnly: false })
    expect(next).toContain('    volumes:\n      - "/srv/ds:/ds"')
    expect(next).toContain('    ports:')
  })

  test('removeComposeMount drops matching entries and keeps the rest', () => {
    const two = `services:
  a:
    image: img
    volumes:
      - "/a:/app"
      - "/b:/data:ro"
`
    const removed = removeComposeMount(two, { source: '/a', target: '/app', readOnly: false })
    expect(removed).not.toContain('/a:/app')
    expect(removed).toContain('/b:/data:ro')
    expect(removeComposeMount(two, { source: '/b', target: '/data', readOnly: true }))
      .not.toContain('/b:/data')
    expect(removeComposeMount(two, { source: '/nope', target: '/x', readOnly: false })).toBe(two)
  })

  test('named volume mappings survive list rewrites', () => {
    const yaml = `services:
  a:
    image: img
    volumes:
      - "/a:/app"
volumes:
  data:
`
    const removed = removeComposeMount(yaml, { source: '/a', target: '/app', readOnly: false })
    expect(removed).not.toContain('/a:/app')
    expect(removed).toContain('volumes:\n  data:')
    const replaced = setComposeMounts(yaml, [{ source: '/b', target: '/data', readOnly: false }])
    expect(replaced).toContain('"/b:/data"')
    expect(replaced).toContain('volumes:\n  data:')
  })

  test('removeComposeMount prunes emptied volumes and untouched keys survive', () => {
    const removed = removeComposeMount(base, { source: '/data/config', target: '/config', readOnly: false })
    expect(removed).not.toContain('volumes:')
    expect(removed).not.toContain('/data/config')
    expect(removed).toContain('ports:')
    expect(removed).toContain('restart: unless-stopped')
  })

  test('dropping every row clears the key without matching a sibling indent', () => {
    const yaml = `services:
  a:
    image: img
    ports:
      - "1:1"
environment:
  - "2:2"
`
    const cleared = setComposePorts(yaml, [])
    expect(cleared).not.toContain('    ports:')
    expect(cleared).toContain('environment:')
    expect(cleared).toContain('  - "2:2"')
  })

  test('retainUsedPaths keeps in-use and shared host paths only', () => {
    const mounts = parseComposeMounts(`    volumes:
      - "/keep:/app"
      - "/shared:/x"
      - "nv/vol:/named"`)
    expect(retainUsedPaths(['/keep', '/gone', '/shared:/x', '/keep:/app:ro'], mounts))
      .toEqual(['/keep', '/shared:/x', '/keep:/app:ro'])
    expect(retainUsedPaths(null, [])).toEqual([])
    expect(retainUsedPaths(undefined, [])).toEqual([])
    expect(afterRemoveSharedPaths(
      ['/keep', '/gone', '/keep:/app'],
      { source: '/gone', target: '/x', readOnly: false },
      [],
    )).toEqual(['/keep', '/keep:/app'])
    expect(afterRemoveSharedPaths(
      ['/keep', '/gone'],
      { source: '/gone', target: '/x', readOnly: false },
      parseComposeMounts('    volumes:\n      - "/keep:/app"\n'),
    )).toEqual(['/keep'])
    expect(afterRemoveSharedPaths(
      ['/secret', '/gone', '/keep'],
      { source: '/gone', target: '/x', readOnly: false },
      parseComposeMounts('    volumes:\n      - "/keep:/app"\n'),
    )).toEqual(['/secret', '/keep'])
  })

  test('composeMountFromDraft normalizes or rejects', () => {
    expect(composeMountFromDraft({ source: ' /a ', target: ' /b ', readOnly: true }))
      .toEqual({ source: '/a', target: '/b', readOnly: true })
    expect(composeMountFromDraft({ source: 'plex-config', target: '/config', readOnly: false }))
      .toEqual({ source: 'plex-config', target: '/config', readOnly: false })
    expect(composeMountFromDraft({ source: 'rel path', target: '/b', readOnly: false })).toBeNull()
    expect(composeMountFromDraft({ source: '/a', target: '/', readOnly: false })).toBeNull()
    expect(composeBindFromDraft({ source: 'plex-config', target: '/config', readOnly: false })).toBeNull()
    expect(composeBindFromDraft({ source: '/a', target: '/b', readOnly: false }))
      .toEqual({ source: '/a', target: '/b', readOnly: false })
  })

  test('setComposeMounts keeps a deleted first-service bind out of later services', () => {
    const yaml = `services:
  a:
    image: img-a
    volumes:
      - "/a:/a"
  b:
    image: img-b
    volumes:
      - "/b:/b"
      - type: bind
        source: /secret
        target: /run/secret
`
    const slots = parseComposeMountSlots(yaml).filter((row) => row.source !== '/a')
    const next = setComposeMounts(yaml, slots)
    expect(next).not.toContain('/a:/a')
    expect(next).toContain('  a:\n    image: img-a\n  b:')
    expect(next).toContain('"/b:/b"')
    expect(next).toContain('type: bind')
    expect(next).toContain('source: /secret')
    expect(parseComposeMounts(next)).toEqual([
      { kind: 'bind', source: '/b', target: '/b', readOnly: false },
    ])
  })

  test('setComposeMounts replaces the volumes list', () => {
    const next = setComposeMounts(base, [
      { source: '/data/media', target: '/media', readOnly: true },
    ])
    expect(parseComposeMounts(next)).toEqual([
      { kind: 'bind', source: '/data/media', target: '/media', readOnly: true },
    ])
    expect(next).not.toContain('/data/config')
    expect(setComposeMounts(base, [])).not.toContain('volumes:')
  })

  test('setComposeMounts keeps long-form volume objects', () => {
    const yaml = `services:
  a:
    image: img
    volumes:
      - "/a:/app"
      - type: bind
        source: /secret
        target: /run/secret
        read_only: true
volumes:
  data:
`
    const next = setComposeMounts(yaml, [{ source: '/b', target: '/data', readOnly: false }])
    expect(next).toContain('"/b:/data"')
    expect(next).not.toContain('/a:/app')
    expect(next).toContain('type: bind')
    expect(next).toContain('source: /secret')
    expect(next).toContain('target: /run/secret')
    expect(next).toContain('volumes:\n  data:')
    const emptied = setComposeMounts(yaml, [])
    expect(emptied).not.toContain('/a:/app')
    expect(emptied).toContain('type: bind')
    expect(emptied).toContain('source: /secret')
  })

  test('extract and replace keep the Application compose block', () => {
    const document = `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  compose: |
    services:
      whoami:
        image: traefik/whoami
        ports:
          - "8080:80"
    restart: unless-stopped
`
    expect(extractComposeBlock(document)).toContain('image: traefik/whoami')
    const rewritten = replaceComposeBlock(document, setComposePorts(extractComposeBlock(document)!, [
      { hostPort: 9090, containerPort: 80, proto: 'tcp' },
    ]))
    expect(rewritten).toContain('      - "9090:80"')
    expect(rewritten).toContain('  compose: |')
    expect(rewritten).not.toContain('8080')
  })

  test('applyComposeDocumentDrafts replaces ports and volumes', () => {
    const document = `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  compose: |
    services:
      whoami:
        image: traefik/whoami
        ports:
          - "8080:80"
        volumes:
          - "/data/config:/config"
`
    const next = applyComposeDocumentDrafts(document, {
      ports: [{ hostPort: 8181, containerPort: 80, proto: 'tcp' }],
      mounts: [{ source: '/srv/ds', target: '/ds', readOnly: false }],
    })
    expect(next).toContain('- "8181:80"')
    expect(next).toContain('"/srv/ds:/ds"')
    expect(next).not.toContain('8080')
    expect(next).not.toContain('/data/config')
    expect(applyComposeDocumentDrafts(document, { ports: [], mounts: [] })).not.toContain('ports:')
    expect(applyComposeDocumentDrafts('kind: Application\n', {
      ports: [{ hostPort: 80, containerPort: 80, proto: 'tcp' }],
      mounts: [],
    })).toBeNull()
    const named = applyComposeDocumentDrafts(document, {
      ports: [{ hostPort: 8080, containerPort: 80, proto: 'tcp' }],
      mounts: [{ source: 'plex-config', target: '/config', readOnly: false }],
    })
    expect(named).toContain('"plex-config:/config"')
    const portsOnly = applyComposeDocumentDrafts(document, {
      ports: [{ hostPort: 9000, containerPort: 80, proto: 'tcp' }],
    })
    expect(portsOnly).toContain('- "9000:80"')
    expect(portsOnly).toContain('"/data/config:/config"')
    expect(extractApplicationSharedPaths(next!)).toEqual(['/srv/ds'])
    expect(extractApplicationSharedPaths(named!)).toEqual([])
    expect(extractApplicationSharedPaths(portsOnly!)).toEqual([])
  })

  test('custom YAML host binds write spec.sharedPaths', () => {
    const document = `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  compose: |
    services:
      whoami:
        image: traefik/whoami
        volumes:
          - "/data/config:/config"
`
    const next = applyComposeDocumentDrafts(document, {
      mounts: [
        { source: '/Users/me/photos', target: '/photos', readOnly: false },
        { source: 'whoami-data', target: '/data', readOnly: false },
      ],
    })
    expect(next).toContain('"/Users/me/photos:/photos"')
    expect(next).toContain('"whoami-data:/data"')
    expect(extractApplicationSharedPaths(next!)).toEqual(['/Users/me/photos'])
    expect(ensureApplicationSharedPaths(document)).toContain('  sharedPaths:\n    - "/data/config"')
    expect(extractApplicationSharedPaths(ensureApplicationSharedPaths(document))).toEqual(['/data/config'])
  })

  test('sharedPaths merge keeps unparsed bind allowlists', () => {
    const document = `apiVersion: barkvisor.dev/v1
kind: Application
metadata:
  name: whoami
spec:
  runtime: device
  sharedPaths:
    - "/secret"
    - "/data/config"
  compose: |
    services:
      whoami:
        image: traefik/whoami
        volumes:
          - "/data/config:/config"
          - type: bind
            source: /secret
            target: /run/secret
            read_only: true
`
    const next = applyComposeDocumentDrafts(document, {
      mounts: [{ source: '/media', target: '/media', readOnly: false }],
    })
    expect(next).toContain('"/media:/media"')
    expect(next).not.toContain('/data/config:/config')
    expect(next).toContain('type: bind')
    expect(next).toContain('source: /secret')
    expect(extractApplicationSharedPaths(next!)).toEqual(['/secret', '/media'])
    expect(mergeApplicationSharedPaths(
      ['/secret', '/data/config'],
      parseComposeMounts(extractComposeBlock(document)!),
      [{ source: '/media', target: '/media', readOnly: false }],
    )).toEqual(['/secret', '/media'])
  })
})
