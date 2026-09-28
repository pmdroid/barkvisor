import type { PortForwardRule } from '../api/types'

/** `hostIP` is the compose spelling of the same idea; a Workload rule uses `host`. */
export type BindField = 'host' | 'hostIP'
export type BindableRule = PortForwardRule & { hostIP?: string }

/**
 * Apply a bind address typed into the editor to one rule.
 *
 * A blank bind means "every IPv4 interface", so an empty box drops the key
 * rather than storing `''` — the API rejects an empty bind address outright.
 * Dropping it also leaves the key absent on save, which is what lets the API
 * inherit a stored bind instead of widening one the user never touched.
 * Surrounding whitespace is trimmed, so a stray space never becomes a bind.
 */
export function applyPortForwardBind(
  rule: BindableRule,
  bindField: BindField,
  raw: string,
): BindableRule {
  const bind = raw.trim()
  const next: BindableRule = { ...rule }
  if (bind) next[bindField] = bind
  else delete next[bindField]
  return next
}
