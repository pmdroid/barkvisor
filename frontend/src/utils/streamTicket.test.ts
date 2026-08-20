import { describe, expect, test } from 'bun:test'
import { needsHomeSession, streamSocketQuery } from './streamTicket'

const self = { hostId: 'desk-1', role: 'self', reachability: 'ok' }
const member = { hostId: 'peer-1', role: 'member', reachability: 'ok' }

describe('streamTicket (PAS-237)', () => {
  test('member tunnels mint Home session; self stays ticket-only', () => {
    expect(needsHomeSession(undefined)).toBe(false)
    expect(needsHomeSession(null)).toBe(false)
    expect(needsHomeSession(self)).toBe(false)
    expect(needsHomeSession(member)).toBe(true)
  })

  test('socket query is ticket plus optional session', () => {
    expect(streamSocketQuery('local-ticket')).toBe('ticket=local-ticket')
    expect(streamSocketQuery('local-ticket', null)).toBe('ticket=local-ticket')
    const memberQuery = streamSocketQuery('member-ticket', 'home-session')
    expect(memberQuery).toContain('ticket=member-ticket')
    expect(memberQuery).toContain('session=home-session')
    expect(memberQuery).not.toContain('token=')
  })
})
