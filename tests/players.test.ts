import request from 'supertest'
import { describe, expect, it, vi } from 'vitest'
import { db, queryResult, rpcResult } from './helpers/supabase.js'
import { createApp } from '../src/app.js'

const app = createApp()
const body = { passcode: 'u8-trainer', groupId: 'u8', nickname: 'Lion', jerseyNumber: 0, jerseyColor: 'blue', heightCm: 120, weightKg: 25, mascotId: 'lion', eyeColor: 'green', gender: 'girl' }
const fields = { p_nickname: 'Lion', p_jersey_number: 0, p_jersey_color: 'blue', p_height_cm: 120, p_weight_kg: 25, p_mascot_id: 'lion', p_eye_color: 'green', p_gender: 'girl' }
const player = { id: 'child', group_id: 'u8', nickname: 'Lion' }
const ratingBody = { passcode: body.passcode, planId: 'plan-u8', categoryId: 'dribbling', rating: 2 }

describe('MUST: players CRUD and promotion', () => {
  it.each([undefined, 'u8'])('never selects parent codes in the public roster (group=%s)', async (groupId) => {
    const query = queryResult([player])
    const res = await request(app).get('/players').query(groupId ? { groupId } : {})
    expect(res.status).toBe(200)
    expect(res.body).toEqual([player])
    expect(db.from).toHaveBeenCalledExactlyOnceWith('players')
    const columns = query.select.mock.calls[0][0].split(',').map((column: string) => column.trim())
    expect(columns).toEqual(['id', 'group_id', 'nickname', 'jersey_number', 'jersey_color', 'eye_color', 'gender', 'height_cm', 'weight_kg', 'mascot_id', 'created_at', 'updated_at'])
    expect(columns).not.toContain('parent_code')
    expect(columns).not.toContain('*')
    expect(query.order).toHaveBeenCalledWith('nickname')
    if (groupId) expect(query.eq).toHaveBeenCalledExactlyOnceWith('group_id', groupId)
    else expect(query.eq).not.toHaveBeenCalled()
  })

  it('creates a player with all fields used by the frontend', async () => {
    rpcResult(player)
    const res = await request(app).post('/players').send(body)
    expect(res.status).toBe(201)
    expect(res.body).toEqual(player)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('create_player', { passcode: body.passcode, p_group_id: 'u8', ...fields })
  })

  it('passes null for omitted optional player fields', async () => {
    rpcResult(player)
    const res = await request(app).post('/players').send({ passcode: body.passcode, groupId: 'u8', nickname: 'Lion' })
    expect(res.status).toBe(201)
    expect(db.rpc).toHaveBeenCalledWith('create_player', { passcode: body.passcode, p_group_id: 'u8', p_nickname: 'Lion', p_jersey_number: null, p_jersey_color: null, p_height_cm: null, p_weight_kg: null, p_mascot_id: null, p_eye_color: null, p_gender: null })
  })

  it.each(['u8', 'u10'])('edits/promotes the same player to %s with the current group code', async (groupId) => {
    rpcResult({ ...player, group_id: groupId })
    const res = await request(app).put('/players/child').send({ ...body, groupId })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ ...player, group_id: groupId })
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('update_player', { passcode: 'u8-trainer', p_id: 'child', p_group_id: groupId, ...fields })
    expect(db.from).not.toHaveBeenCalled()
  })

  it('deletes the requested player', async () => {
    rpcResult(null)
    const res = await request(app).delete('/players/child').send({ passcode: body.passcode })
    expect(res.status).toBe(204)
    expect(res.text).toBe('')
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('delete_player', { passcode: body.passcode, p_id: 'child' })
  })

  for (const method of ['post', 'put', 'delete'] as const) {
    it.each(['wrong', 'PARENT', 'u10-trainer'])(`${method} rejects unauthorized code %s`, async (passcode) => {
      rpcResult(null, { message: 'invalid passcode' })
      const res = await request(app)[method](method === 'post' ? '/players' : '/players/child').send({ ...body, passcode })
      expect(res.status).toBe(401)
      expect(res.body).toEqual({ error: 'invalid passcode' })
      expect(db.rpc).toHaveBeenCalledOnce()
      expect(db.rpc.mock.calls[0][1]).toMatchObject({ passcode })
      expect(db.from).not.toHaveBeenCalled()
    })
  }

  it.each(['put', 'delete'] as const)('%s returns 404 for a missing player', async (method) => {
    rpcResult(null, { message: 'Player not found' })
    const res = await request(app)[method]('/players/missing').send(body)
    expect(res.status).toBe(404)
    expect(res.body).toEqual({ error: 'Player not found' })
  })
})

describe('MUST: individual and historical group progress', () => {
  it('returns all individual history across groups, filtering only by player identity', async () => {
    const rows = [
      { id: 'old', player_id: 'child', plan_id: 'plan-u8', category_id: 'dribbling', rating: 1, created_at: '2026-09-01T10:00:00Z' },
      { id: 'new', player_id: 'child', plan_id: 'plan-u10', category_id: 'dribbling', rating: 3, created_at: '2026-09-19T10:00:00Z' },
    ]
    const query = queryResult(rows)
    const res = await request(app).get('/players/child/progress?groupId=u10')
    expect(res.status).toBe(200)
    expect(res.body).toEqual(rows)
    expect(db.from).toHaveBeenCalledExactlyOnceWith('player_progress_ratings')
    expect(query.select).toHaveBeenCalledExactlyOnceWith('*')
    expect(query.eq).toHaveBeenCalledExactlyOnceWith('player_id', 'child')
    expect(query.order).toHaveBeenCalledExactlyOnceWith('created_at')
  })

  it.each(['u8', 'u10'])('scopes %s progress by the plan group even when the player has moved', async (groupId) => {
    const rows = [{ rating: 2, created_at: '2026-09-19T10:00:00Z', players: { ...player, group_id: 'u10' }, plans: { id: `plan-${groupId}`, group_id: groupId }, skill_categories: { id: 'dribbling', label: 'Dribbling', emoji: '⛹️' } }]
    const query = queryResult(rows)
    const res = await request(app).get(`/groups/${groupId}/progress`)
    expect(res.status).toBe(200)
    expect(res.body).toEqual(rows)
    expect(db.from).toHaveBeenCalledExactlyOnceWith('player_progress_ratings')
    expect(query.select).toHaveBeenCalledExactlyOnceWith('rating, created_at, players!inner(id, nickname, group_id), plans!inner(id, group_id), skill_categories(id, label, emoji)')
    expect(query.eq).toHaveBeenCalledExactlyOnceWith('plans.group_id', groupId)
    expect(query.order).toHaveBeenCalledExactlyOnceWith('created_at')
  })

  it.each([1, 2, 3])('records rating %i through the authorized upsert RPC', async (rating) => {
    const row = { id: 'rating', player_id: 'child', plan_id: 'plan-u8', category_id: 'dribbling', rating }
    rpcResult(row)
    const res = await request(app).post('/players/child/progress').send({ ...ratingBody, rating })
    expect(res.status).toBe(201)
    expect(res.body).toEqual(row)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('rate_player', { passcode: body.passcode, p_player_id: 'child', p_plan_id: 'plan-u8', p_category_id: 'dribbling', p_rating: rating })
  })

  it.each([0, 4, 1.5, '2', null])('rejects invalid rating %s without a database call', async (rating) => {
    const res = await request(app).post('/players/child/progress').send({ ...ratingBody, rating })
    expect(res.status).toBe(400)
    expect(db.rpc).not.toHaveBeenCalled()
  })

  it.each(['passcode', 'planId', 'categoryId'])('requires %s when rating', async (field) => {
    const res = await request(app).post('/players/child/progress').send({ ...ratingBody, [field]: '' })
    expect(res.status).toBe(400)
    expect(db.rpc).not.toHaveBeenCalled()
  })

  it.each(['wrong', 'PARENT', 'u10-trainer'])('rejects rating with %s', async (passcode) => {
    rpcResult(null, { message: 'invalid passcode' })
    const res = await request(app).post('/players/child/progress').send({ ...ratingBody, passcode })
    expect(res.status).toBe(401)
    expect(db.rpc).toHaveBeenCalledWith('rate_player', expect.objectContaining({ passcode }))
  })

  it('returns 404 when rating a missing player', async () => {
    rpcResult(null, { message: 'Player not found' })
    const res = await request(app).post('/players/missing/progress').send(ratingBody)
    expect(res.status).toBe(404)
    expect(res.body).toEqual({ error: 'Player not found' })
  })

  it.each([
    ['Plan not found', 404],
    ['Category not found', 404],
    ['Plan does not belong to player group', 400],
    ['Category does not belong to player sport', 400],
    ['Category is not available for player group', 400],
  ])('maps the rating domain error "%s" to HTTP %i', async (message, status) => {
    rpcResult(null, { message })
    const res = await request(app).post('/players/child/progress').send(ratingBody)
    expect(res.status).toBe(status)
    expect(res.body).toEqual({ error: message })
  })
})

describe('MUST: parent code issue, read and revoke', () => {
  it.each(['ABC234', null])('reads the current code %s only with the player group trainer code', async (parentCode) => {
    const query = queryResult({ group_id: 'u8', parent_code: parentCode })
    rpcResult(true)
    const res = await request(app).get('/players/child/parent-code').query({ passcode: body.passcode, groupId: 'u10' })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ parentCode })
    expect(query.eq).toHaveBeenCalledExactlyOnceWith('id', 'child')
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: body.passcode })
  })

  it('issues a six-character code and returns the exact persisted value', async () => {
    rpcResult(null)
    const res = await request(app).post('/players/child/parent-code').send({ passcode: body.passcode })
    expect(res.status).toBe(200)
    expect(res.body.parentCode).toMatch(/^[ABCDEFGHJKLMNPQRSTUVWXYZ23456789]{6}$/)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('set_player_parent_code', { passcode: body.passcode, p_id: 'child', p_code: res.body.parentCode })
  })

  it('retries a unique-code collision with a new code', async () => {
    const random = vi.spyOn(Math, 'random').mockReturnValueOnce(0).mockReturnValue(0.5)
    try {
      rpcResult(null, { code: '23505', message: 'duplicate code' })
      rpcResult(null)
      const res = await request(app).post('/players/child/parent-code').send({ passcode: body.passcode })
      expect(res.status).toBe(200)
      expect(db.rpc).toHaveBeenCalledTimes(2)
      const first = db.rpc.mock.calls[0][1] as { p_code: string }
      const second = db.rpc.mock.calls[1][1] as { p_code: string }
      expect(first.p_code).not.toBe(second.p_code)
      expect(res.body.parentCode).toBe(second.p_code)
    } finally {
      random.mockRestore()
    }
  })

  it('stops after five collisions and never returns an unpersisted code', async () => {
    for (let i = 0; i < 5; i++) rpcResult(null, { code: '23505', message: 'duplicate code' })
    const res = await request(app).post('/players/child/parent-code').send({ passcode: body.passcode })
    expect(res.status).toBe(500)
    expect(res.body).toEqual({ error: 'Could not generate a unique parent code, try again' })
    expect(db.rpc).toHaveBeenCalledTimes(5)
  })

  it('revokes by persisting null', async () => {
    rpcResult(null)
    const res = await request(app).delete('/players/child/parent-code').send({ passcode: body.passcode })
    expect(res.status).toBe(204)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('set_player_parent_code', { passcode: body.passcode, p_id: 'child', p_code: null })
  })

  for (const method of ['get', 'post', 'delete'] as const) {
    it.each(['wrong', 'PARENT', 'u10-trainer'])(`${method} parent-code rejects %s`, async (passcode) => {
      if (method === 'get') {
        queryResult({ group_id: 'u8', parent_code: 'SECRET' })
        rpcResult(false)
      } else rpcResult(null, { message: 'invalid passcode' })
      const call = request(app)[method]('/players/child/parent-code')
      const res = await (method === 'get' ? call.query({ passcode }) : call.send({ passcode }))
      expect(res.status).toBe(401)
      expect(res.body).toEqual({ error: 'invalid passcode' })
      expect(db.rpc).toHaveBeenCalledOnce()
      expect(db.rpc.mock.calls[0][1]).toMatchObject(method === 'get' ? { p_group_id: 'u8', input: passcode } : { p_id: 'child', passcode })
    })

    it(`${method} parent-code returns 404 for a missing player`, async () => {
      if (method === 'get') queryResult(null)
      else rpcResult(null, { message: 'Player not found' })
      const call = request(app)[method]('/players/missing/parent-code')
      const res = await (method === 'get' ? call.query({ passcode: body.passcode }) : call.send({ passcode: body.passcode }))
      expect(res.status).toBe(404)
      expect(res.body).toEqual({ error: 'Player not found' })
    })

    it(`${method} parent-code requires a passcode before accessing data`, async () => {
      const res = await request(app)[method]('/players/child/parent-code')
      expect(res.status).toBe(400)
      expect(db.rpc).not.toHaveBeenCalled()
      expect(db.from).not.toHaveBeenCalled()
    })
  }
})
