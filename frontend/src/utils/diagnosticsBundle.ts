import type { TaskEvent } from '../api/types'

export const DIAGNOSTICS_BUNDLE_POST_PATH = '/diagnostics/bundle'
export const DIAGNOSTICS_BUNDLE_DEFAULT_FILENAME = 'barkvisor-diagnostics.tar.gz'

/** GET path for the completed bundle. Bearer/API-key — not `?ticket=`. */
export function diagnosticsBundleDownloadPath(taskID: string): string {
  return `/diagnostics/bundle/${encodeURIComponent(taskID)}/download`
}

export function filenameFromContentDisposition(header: string | undefined | null): string | null {
  if (!header) return null
  const match = /filename="([^"]+)"/i.exec(header)
  const name = match?.[1]?.trim()
  return name ? name : null
}

export function saveBlob(blob: Blob, filename: string) {
  const href = URL.createObjectURL(blob)
  try {
    const link = document.createElement('a')
    link.href = href
    link.download = filename
    link.rel = 'noopener'
    document.body.appendChild(link)
    link.click()
    link.remove()
  } finally {
    URL.revokeObjectURL(href)
  }
}

type HeaderMap = { get?(name: string): string | undefined } & Record<string, unknown>

function headerValue(headers: HeaderMap | undefined, name: string): string | undefined {
  if (!headers) return undefined
  const direct = headers[name] ?? headers[name.toLowerCase()]
  if (typeof direct === 'string') return direct
  return headers.get?.(name) ?? headers.get?.(name.toLowerCase())
}

/** POST bundle, poll the task, then GET the archive with the same Bearer session. */
export async function requestDiagnosticsBundle(deps: {
  post: (path: string) => Promise<{ data: { taskID: string } }>
  poll: (taskID: string) => Promise<Pick<TaskEvent, 'status' | 'error'>>
  download: (path: string) => Promise<{ data: Blob; headers?: HeaderMap }>
  save: (blob: Blob, filename: string) => void
}): Promise<void> {
  const { data } = await deps.post(DIAGNOSTICS_BUNDLE_POST_PATH)
  if (!data.taskID) throw new Error('Diagnostic bundle did not return a task')
  const event = await deps.poll(data.taskID)
  if (event.status !== 'completed') {
    throw new Error(event.error || 'Diagnostic bundle failed')
  }
  const file = await deps.download(diagnosticsBundleDownloadPath(data.taskID))
  const filename =
    filenameFromContentDisposition(headerValue(file.headers, 'content-disposition'))
    ?? DIAGNOSTICS_BUNDLE_DEFAULT_FILENAME
  deps.save(file.data, filename)
}
