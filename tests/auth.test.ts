import request from 'supertest'
import { describe, expect, it } from 'vitest'
import { db, rpcResult } from './helpers/supabase.js'
import { createApp } from '../src/app.js'

const app = createApp()

describe('MUST: group access', () => {
  it.each([
    ['trainer', [{ kind: 'trainer', player_id: null, player_nickname: null }], { valid: true, kind: 'trainer' }],
    ['parent', [{ kind: 'parent', player_id: 'child', player_nickname: 'Lion' }], { valid: true, kind: 'parent', player: { id: 'child', nickname: 'Lion' } }],
    ['invalid', [], { valid: false }],
  ])('returns the UI access contract for %s', async (_kind, data, expected) => {
    rpcResult(data)
    const res = await request(app).post('/auth/verify-passcode').send({ groupId: 'u8', passcode: 'entered-code' })
    expect(res.status).toBe(200)
    expect(res.body).toEqual(expected)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_group_access', { p_group_id: 'u8', input: 'entered-code' })
    expect(db.from).not.toHaveBeenCalled()
  })

  it.each([{ groupId: 'u8' }, { passcode: 'code' }, { groupId: 'u8', passcode: '' }])('rejects incomplete login %j before querying the database', async (body) => {
    const res = await request(app).post('/auth/verify-passcode').send(body)
    expect(res.status).toBe(400)
    expect(db.rpc).not.toHaveBeenCalled()
  })

  it('does not grant access when verification fails', async () => {
    rpcResult(null, { message: 'verification failed' })
    const res = await request(app).post('/auth/verify-passcode').send({ groupId: 'u8', passcode: 'code' })
    expect(res.status).toBe(500)
    expect(res.body).toEqual({ error: 'verification failed' })
  })
})
