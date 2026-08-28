/** Catalog recipe helpers for Template deploy (no extra schema). */

import { normalizeImageArch } from './imageArch'
import type {
  DeployTemplateRecipe,
  PortForwardRule,
  TemplateCatalogImage,
  TemplateInput,
  VMTemplate,
} from '../api/types'

type TemplateInputDef = {
  id: string
  required?: boolean
  default?: string
}

export function templateDeclaresSshKeys(
  inputs: TemplateInputDef[] | null | undefined,
): boolean {
  return (inputs ?? []).some((input) => input.id === 'ssh_keys')
}

export function templateRequiresSshKeys(
  inputs: TemplateInputDef[] | null | undefined,
): boolean {
  return (inputs ?? []).some((input) => input.id === 'ssh_keys' && !!input.required)
}

export function visibleTemplateInputs<T extends { id: string }>(
  inputs: T[] | null | undefined,
): T[] {
  return (inputs ?? []).filter((input) => input.id !== 'ssh_keys')
}

export function templateInputsComplete(
  defs: Array<{ id: string; required?: boolean; minLength?: number }> | null | undefined,
  values: Record<string, string>,
): boolean {
  return visibleTemplateInputs(defs)
    .filter((input) => input.required)
    .every((input) => {
      const val = values[input.id] ?? ''
      if (!val) return false
      if (input.minLength && val.length < input.minLength) return false
      return true
    })
}

export function collectTemplateDeployInputs(
  defs: TemplateInputDef[] | null | undefined,
  opts: { values?: Record<string, string>; sshAuthorizedKey?: string } = {},
): Record<string, string> {
  const inputs: Record<string, string> = {}
  for (const input of defs ?? []) {
    if (input.id === 'ssh_keys') continue
    const value = opts.values?.[input.id] ?? input.default ?? ''
    if (value !== '') inputs[input.id] = value
  }
  if (opts.sshAuthorizedKey) inputs.ssh_keys = opts.sshAuthorizedKey
  return inputs
}

export function catalogImageForArch(
  template: {
    catalogImages?: TemplateCatalogImage[] | null
  },
  hostArch: string | null | undefined,
): TemplateCatalogImage | null {
  const want = normalizeImageArch(hostArch)
  if (!want) return null
  const match = (template.catalogImages ?? []).find((img) => normalizeImageArch(img.arch) === want)
  if (!match?.downloadUrl?.trim()) return null
  return match
}

export function buildDeployRecipe(
  template: Pick<
    VMTemplate,
    | 'name'
    | 'slug'
    | 'inputs'
    | 'userDataTemplate'
    | 'cpuCount'
    | 'memoryMB'
    | 'diskSizeGB'
    | 'networkMode'
    | 'portForwards'
    | 'architectures'
    | 'minMemoryMB'
    | 'requiredFeatures'
    | 'catalogImages'
  >,
  hostArch: string | null | undefined,
): DeployTemplateRecipe | undefined {
  const image = catalogImageForArch(template, hostArch)
  if (!image) return undefined
  return {
    name: template.name,
    slug: template.slug,
    inputs: template.inputs as TemplateInput[],
    userDataTemplate: template.userDataTemplate,
    cpuCount: template.cpuCount,
    memoryMB: template.memoryMB,
    diskSizeGB: template.diskSizeGB,
    networkMode: template.networkMode,
    portForwards: (template.portForwards ?? undefined) as PortForwardRule[] | undefined,
    architectures: template.architectures,
    minMemoryMB: template.minMemoryMB ?? undefined,
    requiredFeatures: template.requiredFeatures,
    image: {
      downloadUrl: image.downloadUrl,
      sha256: image.sha256 ?? undefined,
      sha512: image.sha512 ?? undefined,
      arch: image.arch,
      imageType: image.imageType,
      name: image.name,
      slug: image.slug,
    },
  }
}

export type TemplateWebForward = {
  protocol: string
  hostPort: number
  httpPath?: string | null
}

/** This Device NAT only. Member localhost would be the wrong machine. */
export function natWebUILinks(opts: {
  templateName: string
  networkMode: string
  isSelfDevice: boolean
  portForwards?: TemplateWebForward[] | null
}): { href: string; label: string }[] {
  if (!opts.isSelfDevice || opts.networkMode !== 'nat') return []
  return (opts.portForwards ?? [])
    .filter((rule) => rule.protocol.toLowerCase() === 'tcp' && !!rule.httpPath)
    .map((rule) => {
      const path = rule.httpPath!.startsWith('/') ? rule.httpPath! : `/${rule.httpPath}`
      const href =
        rule.hostPort === 80
          ? `http://127.0.0.1${path === '/' ? '/' : path}`
          : `http://127.0.0.1:${rule.hostPort}${path}`
      return { href, label: `Open ${opts.templateName}` }
    })
}
