import { afterEach, describe, expect, mock, test } from 'bun:test'
import api from '../api/client'
import { useTaskPoller } from './useTaskPoller'

const originalGet = api.get

describe('useTaskPoller (PAS-34)', () => {
  afterEach(() => {
    api.get = originalGet
  })

  test('polls a member task through the Home proxy path', async () => {
    const get = mock(() =>
      Promise.resolve({
        data: {
          taskID: 't1',
          kind: 'vmProvision',
          status: 'completed',
          progress: 100,
          error: null,
          resultPayload: null,
        },
      }),
    )
    api.get = get as typeof api.get
    const { poll } = useTaskPoller()
    const event = await poll('t1', { path: '/home/devices/peer-1/v1/tasks/t1' })
    expect(event.status).toBe('completed')
    expect(get.mock.calls[0]?.[0]).toBe('/home/devices/peer-1/v1/tasks/t1')
  })
})
