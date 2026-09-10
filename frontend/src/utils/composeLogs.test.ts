import { describe, expect, test } from 'bun:test'
import {
  firstPasswordFromLine,
  firstPasswordFromLogs,
  isFirstPasswordLine,
  shortDigest,
} from './composeLogs'

describe('compose logs', () => {
  test('reads the qBittorrent temporary password from a log line', () => {
    const line =
      'qbittorrent  | The WebUI administrator password was not set. A temporary password is provided for this session: s3cretPass'
    expect(firstPasswordFromLine(line)).toBe('s3cretPass')
    expect(isFirstPasswordLine(line)).toBe(true)
    expect(firstPasswordFromLogs(['ready', line, 'done'])).toBe('s3cretPass')
    expect(
      firstPasswordFromLine(
        '2026-09-08T20:41:02.123Z qbittorrent  | A temporary password is provided for this session: helloQB',
      ),
    ).toBe('helloQB')
    expect(
      firstPasswordFromLine('2026-09-08T20:41:02Z qbittorrent  | The WebUI administrator password was not set.'),
    ).toBeNull()
  })

  test('does not invent a password from unrelated lines', () => {
    expect(firstPasswordFromLine('jellyfin | listening on 8096')).toBeNull()
    expect(isFirstPasswordLine('warn: password auth failed')).toBe(false)
    expect(firstPasswordFromLogs(['ok'])).toBeNull()
  })

  test('shortens digests', () => {
    expect(shortDigest('sha256:aaa111bbb222ccc333')).toBe('sha256:aaa111bbb222…')
    expect(shortDigest(null)).toBe('—')
  })
})
