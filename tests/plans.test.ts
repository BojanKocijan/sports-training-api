import request from 'supertest'
import { describe, expect, it } from 'vitest'
import { db, queryResult, rpcResult } from './helpers/supabase.js'
import { createApp } from '../src/app.js'

const app = createApp()
const body = { passcode: 'u8-trainer', groupId: 'u8', trainingDate: '2026-09-19', title: 'Practice', emoji: '🏀', exerciseIds: ['dribble', 'pass'] }
const plan = { id: 'plan-u8', group_id: 'u8', training_date: body.trainingDate, title: body.title, emoji: body.emoji, exercise_ids: body.exerciseIds }

describe('MUST: plans CRUD and group authorization', () => {
  it('lists only the selected group plans in date order', async () => {
    const query = queryResult([plan])
    const res = await request(app).get('/plans?groupId=u8')
    expect(res.status).toBe(200)
    expect(res.body).toEqual([plan])
    expect(db.from).toHaveBeenCalledExactlyOnceWith('plans')
    expect(query.eq).toHaveBeenCalledExactlyOnceWith('group_id', 'u8')
    expect(query.order).toHaveBeenCalledExactlyOnceWith('training_date')
  })

  it('creates a plan with the selected group trainer code', async () => {
    rpcResult(true)
    const query = queryResult(plan)
    const res = await request(app).post('/plans').send(body)
    expect(res.status).toBe(201)
    expect(res.body).toEqual(plan)
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: body.passcode })
    expect(query.insert).toHaveBeenCalledExactlyOnceWith({ group_id: 'u8', training_date: body.trainingDate, title: body.title, emoji: body.emoji, exercise_ids: body.exerciseIds })
  })

  it('edits the existing plan and checks its stored group, ignoring a forged groupId', async () => {
    const lookup = queryResult({ group_id: 'u8' })
    rpcResult(true)
    const mutation = queryResult({ ...plan, title: 'Changed' })
    const res = await request(app).put('/plans/plan-u8').send({ ...body, title: 'Changed', groupId: 'u10' })
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ ...plan, title: 'Changed' })
    expect(lookup.eq).toHaveBeenCalledExactlyOnceWith('id', 'plan-u8')
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: body.passcode })
    expect(mutation.update).toHaveBeenCalledExactlyOnceWith({ training_date: body.trainingDate, title: 'Changed', emoji: body.emoji, exercise_ids: body.exerciseIds, updated_at: expect.any(String) })
    expect(mutation.eq).toHaveBeenCalledExactlyOnceWith('id', 'plan-u8')
  })

  it('deletes only the requested plan after authorizing its stored group', async () => {
    queryResult({ group_id: 'u8' })
    rpcResult(true)
    const mutation = queryResult(null)
    const res = await request(app).delete('/plans/plan-u8').send({ passcode: body.passcode })
    expect(res.status).toBe(204)
    expect(res.text).toBe('')
    expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: body.passcode })
    expect(mutation.delete).toHaveBeenCalledOnce()
    expect(mutation.eq).toHaveBeenCalledExactlyOnceWith('id', 'plan-u8')
  })

  for (const method of ['post', 'put', 'delete'] as const) {
    it.each(['wrong', 'u10-trainer', 'PARENT'])(`${method} rejects %s without writing`, async (passcode) => {
      if (method !== 'post') queryResult({ group_id: 'u8' })
      rpcResult(false)
      const res = await request(app)[method](method === 'post' ? '/plans' : '/plans/plan-u8').send({ ...body, groupId: method === 'post' ? 'u8' : 'u10', passcode })
      expect(res.status).toBe(401)
      expect(res.body).toEqual({ error: 'Invalid passcode' })
      expect(db.rpc).toHaveBeenCalledExactlyOnceWith('verify_passcode', { p_group_id: 'u8', input: passcode })
      expect(db.from).toHaveBeenCalledTimes(method === 'post' ? 0 : 1)
    })

    it(`${method} rejects a missing passcode before database access`, async () => {
      const res = await request(app)[method](method === 'post' ? '/plans' : '/plans/plan-u8').send({ ...body, passcode: undefined })
      expect(res.status).toBe(400)
      expect(db.rpc).not.toHaveBeenCalled()
      expect(db.from).not.toHaveBeenCalled()
    })
  }

  it.each(['put', 'delete'] as const)('%s returns 404 for a missing plan', async (method) => {
    queryResult(null)
    const res = await request(app)[method]('/plans/missing').send(body)
    expect(res.status).toBe(404)
    expect(res.body).toEqual({ error: 'Plan not found' })
    expect(db.rpc).not.toHaveBeenCalled()
    expect(db.from).toHaveBeenCalledTimes(1)
  })

  it.each(['post', 'put'] as const)('%s reports a duplicate group/date conflict', async (method) => {
    if (method === 'put') queryResult({ group_id: 'u8' })
    rpcResult(true)
    queryResult(null, { code: '23505', message: 'duplicate key' })
    const res = await request(app)[method](method === 'post' ? '/plans' : '/plans/plan-u8').send(body)
    expect(res.status).toBe(409)
    expect(res.body).toEqual({ error: 'This group already has a training planned on that date' })
  })
})
