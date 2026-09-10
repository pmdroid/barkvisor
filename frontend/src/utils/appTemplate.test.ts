import { describe, expect, test } from 'bun:test'
import type { AppCatalogEntry, AppTemplateField } from '../api/types'
import {
  applicationDocument,
  applyDevicePrefill,
  catalogFields,
  fieldError,
  isAdvancedField,
  missingRequiredField,
  openUIURL,
  seedTemplateValues,
  uiPortField,
} from './appTemplate'

function field(partial: Partial<AppTemplateField> & Pick<AppTemplateField, 'id' | 'label' | 'kind' | 'target'>): AppTemplateField {
  return {
    required: false,
    ...partial,
  }
}

function app(fields: AppTemplateField[]): AppCatalogEntry {
  return {
    id: 'plex',
    name: 'Plex',
    category: 'Media',
    arches: ['arm64'],
    source: 'big-bear-universal',
    compose: 'services:\n  plex:\n    image: lscr.io/linuxserver/plex\n',
    envSchema: [],
    volumes: [],
    ports: [],
    unsupportedReasons: [],
    ui: { scheme: 'http', path: '/web', proxy: 'direct', basePathEnv: [] },
    fields,
  }
}

describe('appTemplate', () => {
  test('required path blocks apply with the field label', () => {
    const fields = [
      field({ id: 'path-movies', label: 'Movies', kind: 'path', required: true, target: 'volume:/movies' }),
      field({ id: 'PUID', label: 'PUID', kind: 'text', target: 'env:PUID', default: '501' }),
    ]
    expect(missingRequiredField(fields, { PUID: '501' })?.label).toBe('Movies')
    expect(fieldError(fields[0], {})).toBe('Movies is required')
    expect(fieldError(fields[0], { 'path-movies': '/mnt/movies' })).toBe('')
  })

  test('UMASK stays off the main form required check', () => {
    const umask = field({ id: 'umask', label: 'UMASK', kind: 'text', target: 'env:UMASK', required: true })
    expect(isAdvancedField(umask)).toBe(true)
    expect(missingRequiredField([umask], {})).toBeNull()
  })

  test('open UI uses scheme and path', () => {
    expect(openUIURL({ scheme: 'http', path: '/web', host: '192.168.1.20', port: 32400 }))
      .toBe('http://192.168.1.20:32400/web')
  })

  test('device prefill overwrites PUID TZ', () => {
    const fields = [
      field({ id: 'puid', label: 'PUID', kind: 'text', target: 'env:PUID', default: '1000' }),
      field({ id: 'tz', label: 'TZ', kind: 'text', target: 'env:TZ', default: 'UTC' }),
    ]
    const seeded = seedTemplateValues(fields)
    const next = applyDevicePrefill(fields, seeded, { puid: '501', timezone: 'America/Los_Angeles' })
    expect(next.puid).toBe('501')
    expect(next.tz).toBe('America/Los_Angeles')
  })

  test('required secrets are generated', () => {
    const fields = [
      field({ id: 'database-password', label: 'Database password', kind: 'secret', required: true, target: 'env:DB_PASSWORD' }),
    ]
    const seeded = seedTemplateValues(fields)
    expect(seeded['database-password'].length).toBe(24)
  })

  test('apply document keeps catalog compose and template answers', () => {
    const fields = [
      field({ id: 'path-movies', label: 'Movies', kind: 'path', required: true, target: 'volume:/movies' }),
    ]
    const doc = applicationDocument(app(fields), 'plex', { 'path-movies': '/mnt/movies' }, [
      { hostPath: '/mnt/photos', containerPath: '/photos' },
    ])
    expect((doc.metadata as { labels: { catalog: string; 'catalog-source': string } }).labels.catalog).toBe('plex')
    expect((doc.metadata as { labels: { catalog: string; 'catalog-source': string } }).labels['catalog-source']).toBe(
      'big-bear-universal',
    )
    const template = doc.template as { values: Record<string, string>; extraFolders: Array<{ hostPath: string }> }
    expect(template.values['path-movies']).toBe('/mnt/movies')
    expect(template.extraFolders[0].hostPath).toBe('/mnt/photos')
    expect((doc.spec as { compose: string }).compose).toContain('linuxserver/plex')
  })

  test('apply document includes selected gpu share ids', () => {
    const doc = applicationDocument(app([]), 'plex', {}, [], ['0000:00:02.0', 'GPU-aaaa'])
    expect((doc.spec as { gpuShare: Array<{ id: string }> }).gpuShare).toEqual([
      { id: '0000:00:02.0' },
      { id: 'GPU-aaaa' },
    ])
  })

  test('open UI field is the labeled port', () => {
    const fields = [
      field({ id: 'port-32400-tcp', label: 'Open UI', kind: 'port', target: 'port:32400/tcp' }),
      field({ id: 'port-1900-udp', label: 'Port 1900/udp', kind: 'port', target: 'port:1900/udp' }),
    ]
    expect(uiPortField(fields)?.id).toBe('port-32400-tcp')
    expect(catalogFields(app(fields))).toHaveLength(2)
  })
})
