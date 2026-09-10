import type { AppCatalogEntry, AppTemplateField } from '../api/types'

export type AppTemplateValues = Record<string, string>

export type AppTemplateExtraFolder = {
  hostPath: string
  containerPath: string
}

const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'

export function generateSecret(length = 24): string {
  const bytes = new Uint8Array(length)
  crypto.getRandomValues(bytes)
  let out = ''
  for (const byte of bytes) out += alphabet[byte % alphabet.length]
  return out
}

export function envName(field: AppTemplateField): string | null {
  return field.target.startsWith('env:') ? field.target.slice(4) : null
}

export function volumePath(field: AppTemplateField): string | null {
  return field.target.startsWith('volume:') ? field.target.slice(7) : null
}

export function portSpec(field: AppTemplateField): { container: number; proto: string } | null {
  if (!field.target.startsWith('port:')) return null
  const rest = field.target.slice(5)
  const [containerText, proto = 'tcp'] = rest.split('/')
  const container = Number(containerText)
  if (!Number.isFinite(container)) return null
  return { container, proto: proto.toLowerCase() }
}

export function isAdvancedField(field: AppTemplateField): boolean {
  return envName(field) === 'UMASK'
}

export function catalogFields(app: AppCatalogEntry): AppTemplateField[] {
  return app.fields ?? []
}

export function seedTemplateValues(
  fields: AppTemplateField[],
  existing: AppTemplateValues = {},
): AppTemplateValues {
  const values: AppTemplateValues = { ...existing }
  for (const field of fields) {
    if (values[field.id]) continue
    if (field.kind === 'secret') {
      if (field.required) values[field.id] = generateSecret()
      continue
    }
    if (field.default) values[field.id] = field.default
  }
  return values
}

export function applyDevicePrefill(
  fields: AppTemplateField[],
  values: AppTemplateValues,
  prefill: { puid?: string; pgid?: string; timezone?: string },
): AppTemplateValues {
  const next = { ...values }
  for (const field of fields) {
    const name = envName(field)
    if (name === 'PUID' && prefill.puid) next[field.id] = prefill.puid
    if (name === 'PGID' && prefill.pgid) next[field.id] = prefill.pgid
    if (name === 'TZ' && prefill.timezone) next[field.id] = prefill.timezone
  }
  return next
}

export function missingRequiredField(
  fields: AppTemplateField[],
  values: AppTemplateValues,
): AppTemplateField | null {
  return (
    fields.find((field) => {
      if (!field.required || isAdvancedField(field)) return false
      return !(values[field.id] ?? '').trim()
    }) ?? null
  )
}

export function fieldError(
  field: AppTemplateField,
  values: AppTemplateValues,
): string {
  if (!field.required || isAdvancedField(field)) return ''
  if ((values[field.id] ?? '').trim()) return ''
  return `${field.label} is required`
}

export function openUIURL(opts: {
  scheme?: string | null
  path?: string | null
  host: string
  port: number
}): string {
  let scheme = (opts.scheme ?? 'http').trim() || 'http'
  let path = (opts.path ?? '').trim()
  if (path === '/') path = ''
  if (path && !path.startsWith('/')) path = `/${path}`
  return `${scheme}://${opts.host}:${opts.port}${path}`
}

export function uiPortField(fields: AppTemplateField[]): AppTemplateField | null {
  return fields.find((field) => field.kind === 'port' && field.label === 'Open UI')
    ?? fields.find((field) => field.kind === 'port' && portSpec(field)?.proto === 'tcp')
    ?? null
}

export function applicationDocument(
  app: AppCatalogEntry,
  name: string,
  values: AppTemplateValues,
  extraFolders: AppTemplateExtraFolder[] = [],
  gpuShareIds: string[] = [],
): Record<string, unknown> {
  const spec: Record<string, unknown> = {
    runtime: 'device',
    compose: app.compose,
  }
  if (gpuShareIds.length) {
    spec.gpuShare = gpuShareIds.map((id) => ({ id }))
  }
  return {
    apiVersion: 'barkvisor.dev/v1',
    kind: 'Application',
    metadata: { name, labels: { catalog: app.id, 'catalog-source': app.source } },
    template: {
      values,
      extraFolders: extraFolders.filter((row) => row.hostPath.trim() && row.containerPath.trim()),
    },
    spec,
  }
}
