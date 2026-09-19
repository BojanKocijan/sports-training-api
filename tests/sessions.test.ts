import request from 'supertest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { db, queryResult, rpcResult } from './helpers/supabase.js'
import { createApp } from '../src/app.js'

const app = createApp()
const now = '2026-09-19T10:00:10.900Z'
const baseline = { group_id: 'u8', status: 'paused', elapsed_seconds: 20, running_since: null, updated_at: now }
const running = { ...baseline, status: 'running', running_since: '2026-09-19T10:00:00.000Z' }
const credentials = { passcode: 'u8-trainer' }

beforeEach(() => {
  // Fake Date only: Supertest's socket/timer handling continues to use real timers.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(new Date(now))
})
afterEach(() => vi.useRealTimers())

describe('MUST: session reads and clock transitions', () => {
  it('returns an idle clock for a group without a stored session', async () => {
    const query = queryResult(null)
    const res = await request(app).get('/sessions/u8')
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ groupId: 'u8', status: 'idle', elapsedSeconds: 0, updatedAt: now })
    expect(db.from).toHaveBeenCalledExactlyOnceWith('live_sessions')
    expect(query.eq).toHaveBeenCalledExactlyOnceWith('group_id', 'u8')
    expect(db.rpc).not.toHaveBeenCalled()
  })

  it.each([
    [baseline, 20],
    [running, 30],
    [{ ...running, running_since: '2026-09-19T10:01:00Z' }, 20],
    [{ ...running, running_since: null }, 20],
  ])('serializes elapsed time for %j', async (row, elapsedSeconds) => {
    queryResult(row)
    const res = await request(app).get('/sessions/u8')
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ groupId: 'u8', status: row.status, elapsedSeconds, updatedAt: now })
  })

  it.each([
    ['start', null, { ...baseline, status: 'running', elapsed_seconds: 0, running_since: now }],
    ['start', baseline, { ...baseline, status: 'running', running_since: now }],
    ['pause', running, { ...baseline, elapsed_seconds: 30 }],
    ['pause', baseline, baseline],
    ['seek', running, { ...baseline, status: 'running', elapsed_seconds: 120, running_since: now }],
    ['seek', baseline, { ...baseline, elapsed_seconds: 120 }],
    ['seek', null, { ...baseline, elapsed_seconds: 120 }],
  ])('%s transitions from %j', async (action, current, expected) => {
    rpcResult(true)
    const lookup = queryResult(current)
    const mutation = queryResult(expected)
    const res = await request(app).post(`/sessions/u8/${action}`).send({ ...credentials, seconds: 120 })
    expect(res.status).toBe(200)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: credentials.passcode })
    expect(lookup.eq).toHaveBeenCalledExactlyOnceWith('group_id', 'u8')
    expect(mutation.upsert).toHaveBeenCalledExactlyOnceWith(expected)
    expect(res.body).toEqual({ groupId: 'u8', status: expected.status, elapsedSeconds: expected.elapsed_seconds, updatedAt: now })
  })

  it('starting an already running clock preserves its origin and does not write', async () => {
    rpcResult(true)
    const query = queryResult(running)
    const res = await request(app).post('/sessions/u8/start').send(credentials)
    expect(res.status).toBe(200)
    expect(res.body.elapsedSeconds).toBe(30)
    expect(query.upsert).not.toHaveBeenCalled()
    expect(db.from).toHaveBeenCalledTimes(1)
  })

  it('resets the selected group to idle, clearing both elapsed and running time', async () => {
    rpcResult(true)
    const row = { ...baseline, group_id: 'u10', status: 'idle', elapsed_seconds: 0 }
    const query = queryResult(row)
    const res = await request(app).post('/sessions/u10/reset').send({ passcode: 'u10-trainer', groupId: 'u8' })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ groupId: 'u10', status: 'idle', elapsedSeconds: 0, updatedAt: now })
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u10', input: 'u10-trainer' })
    expect(query.upsert).toHaveBeenCalledExactlyOnceWith(row)
  })

  it('seeking to zero is valid', async () => {
    rpcResult(true)
    queryResult(baseline)
    const row = { ...baseline, elapsed_seconds: 0 }
    const query = queryResult(row)
    const res = await request(app).post('/sessions/u8/seek').send({ ...credentials, seconds: 0 })
    expect(res.status).toBe(200)
    expect(res.body.elapsedSeconds).toBe(0)
    expect(query.upsert).toHaveBeenCalledExactlyOnceWith(row)
  })

  it('preserves elapsed time through start → pause → resume → seek → reset', async () => {
    let stored: typeof baseline | typeof running | null = null
    async function control(action: string, time: string, seconds?: number) {
      vi.setSystemTime(new Date(time))
      rpcResult(true)
      if (action !== 'reset') queryResult(stored)
      const mutation = queryResult(null)
      mutation.single.mockImplementation(async () => {
        stored = mutation.upsert.mock.calls[0][0]
        return { data: stored, error: null }
      })
      const res = await request(app).post(`/sessions/u8/${action}`).send({ ...credentials, seconds })
      expect(res.status).toBe(200)
      return res.body
    }
    expect(await control('start', '2026-09-19T10:00:00Z')).toMatchObject({ status: 'running', elapsedSeconds: 0 })
    expect(await control('pause', '2026-09-19T10:00:07Z')).toMatchObject({ status: 'paused', elapsedSeconds: 7 })
    expect(await control('start', '2026-09-19T10:01:00Z')).toMatchObject({ status: 'running', elapsedSeconds: 7 })
    expect(await control('seek', '2026-09-19T10:01:03Z', 120)).toMatchObject({ status: 'running', elapsedSeconds: 120 })
    vi.setSystemTime(new Date('2026-09-19T10:01:08Z'))
    queryResult(stored)
    expect((await request(app).get('/sessions/u8')).body.elapsedSeconds).toBe(125)
    expect(await control('reset', '2026-09-19T10:01:09Z')).toMatchObject({ status: 'idle', elapsedSeconds: 0 })
  })
})

describe('MUST: every session control is trainer-only', () => {
  for (const action of ['start', 'pause', 'seek', 'reset']) {
    it.each(['wrong', 'PARENT', 'u10-trainer'])(`${action} rejects %s without reading or writing session state`, async (passcode) => {
      rpcResult(false)
      const res = await request(app).post(`/sessions/u8/${action}`).send({ passcode, seconds: 30, groupId: 'u10' })
      expect(res.status).toBe(401)
      expect(res.body).toEqual({ error: 'Invalid passcode' })
      expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: passcode })
      expect(db.from).not.toHaveBeenCalled()
    })

    it(`${action} rejects a missing passcode`, async () => {
      const res = await request(app).post(`/sessions/u8/${action}`).send({ seconds: 30 })
      expect(res.status).toBe(400)
      expect(db.rpc).not.toHaveBeenCalled()
      expect(db.from).not.toHaveBeenCalled()
    })

    it(`${action} stops when passcode verification errors`, async () => {
      rpcResult(null, { message: 'verification unavailable' })
      const res = await request(app).post(`/sessions/u8/${action}`).send({ ...credentials, seconds: 30 })
      expect(res.status).toBe(500)
      expect(db.from).not.toHaveBeenCalled()
    })
  }

  it.each([-1, 1.5, '30', null])('rejects invalid seek seconds %s', async (seconds) => {
    const res = await request(app).post('/sessions/u8/seek').send({ ...credentials, seconds })
    expect(res.status).toBe(400)
    expect(db.rpc).not.toHaveBeenCalled()
    expect(db.from).not.toHaveBeenCalled()
  })
})
