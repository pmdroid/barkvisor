import { describe, expect, test } from 'bun:test'
import {
  DIAGNOSTICS_BUNDLE_DEFAULT_FILENAME,
  DIAGNOSTICS_BUNDLE_POST_PATH,
  diagnosticsBundleDownloadPath,
  filenameFromContentDisposition,
  requestDiagnosticsBundle,
} from './diagnosticsBundle'

describe('diagnosticsBundle (PAS-280)', () => {
  test('download path is the real GET route and percent-encodes the task id', () => {
    expect(DIAGNOSTICS_BUNDLE_POST_PATH).toBe('/diagnostics/bundle')
    expect(diagnosticsBundleDownloadPath('task-1')).toBe(
      '/diagnostics/bundle/task-1/download',
    )
    expect(diagnosticsBundleDownloadPath('diagnostic-bundle:deadbeef')).toBe(
      '/diagnostics/bundle/diagnostic-bundle%3Adeadbeef/download',
    )
    expect(diagnosticsBundleDownloadPath('diagnostic-bundle:deadbeef')).not.toContain(
      '?ticket=',
    )
  })

  test('filename comes from Content-Disposition when present', () => {
    expect(filenameFromContentDisposition(undefined)).toBe(null)
    expect(filenameFromContentDisposition('attachment; filename="bundle.tar.gz"')).toBe(
      'bundle.tar.gz',
    )
  })

  test('POST then poll then Bearer download; never mints a stream ticket', async () => {
    const calls: string[] = []
    const blob = new Blob(['archive'])
    await requestDiagnosticsBundle({
      post: async (path) => {
        calls.push(`POST ${path}`)
        return { data: { taskID: 'diagnostic-bundle:cafe' } }
      },
      poll: async (taskID) => {
        calls.push(`POLL ${taskID}`)
        return { status: 'completed', error: null }
      },
      download: async (path) => {
        calls.push(`GET ${path}`)
        expect(path).not.toContain('ticket=')
        return {
          data: blob,
          headers: { 'content-disposition': 'attachment; filename="from-header.tar.gz"' },
        }
      },
      save: (file, filename) => {
        calls.push(`SAVE ${filename}`)
        expect(file).toBe(blob)
      },
    })
    expect(calls).toEqual([
      'POST /diagnostics/bundle',
      'POLL diagnostic-bundle:cafe',
      'GET /diagnostics/bundle/diagnostic-bundle%3Acafe/download',
      'SAVE from-header.tar.gz',
    ])
  })

  test('failed task does not hit download', async () => {
    let downloaded = false
    await expect(
      requestDiagnosticsBundle({
        post: async () => ({ data: { taskID: 't-fail' } }),
        poll: async () => ({ status: 'failed', error: 'disk full' }),
        download: async () => {
          downloaded = true
          return { data: new Blob() }
        },
        save: () => {
          throw new Error('should not save')
        },
      }),
    ).rejects.toThrow('disk full')
    expect(downloaded).toBe(false)
  })

  test('missing Content-Disposition uses the default archive name', async () => {
    let saved = ''
    await requestDiagnosticsBundle({
      post: async () => ({ data: { taskID: 't1' } }),
      poll: async () => ({ status: 'completed', error: null }),
      download: async () => ({ data: new Blob(['x']) }),
      save: (_blob, filename) => {
        saved = filename
      },
    })
    expect(saved).toBe(DIAGNOSTICS_BUNDLE_DEFAULT_FILENAME)
  })
})
