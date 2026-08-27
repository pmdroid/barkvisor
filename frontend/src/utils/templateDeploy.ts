/** Catalog recipe helpers for Template deploy (no extra schema). */

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
