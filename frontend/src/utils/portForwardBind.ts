import type { PortForwardRule } from '../api/types'

/** `hostIP` is the compose spelling of the same idea; a Workload rule uses `host`. */
export type BindField = 'host' | 'hostIP'
export type BindableRule = PortForwardRule & { hostIP?: string }

/** The bind a rule carries right now, or '' when it publishes on every IPv4 interface. */
export function portForwardBind(rule: BindableRule, bindField: BindField): string {
  return (rule[bindField] ?? '').trim()
}

/**
 * Apply a bind address typed into the editor to one rule.
 *
 * Widening a publish — from `127.0.0.1` to every IPv4 interface — must be
 * something the operator asks for, never a side effect of emptying a box.
 * The console saves through the flat VM PATCH, which stores the list verbatim:
 * there is no bind inheritance on that path, so a missing key is read as
 * "every interface" and a cleared box would silently expose the port to the
 * LAN. So an empty box keeps whatever the rule was opened with, and the only
 * way to widen is to type the wildcard address.
 *
 * `opened` is the bind the rule carried when the editor opened. A rule that
 * had no bind stays without one, which is the documented default.
 *
 * Whitespace is trimmed, so a stray space never becomes a bind, and a blank
 * never reaches the API — an empty bind address is a 400.
 */
export function applyPortForwardBind(
  rule: BindableRule,
  bindField: BindField,
  raw: string,
  opened?: string,
): BindableRule {
  const bind = raw.trim()
  const next: BindableRule = { ...rule }
  const keep = (opened ?? portForwardBind(rule, bindField)).trim()
  if (bind) next[bindField] = bind
  else if (keep) next[bindField] = keep
  else delete next[bindField]
  return next
}
