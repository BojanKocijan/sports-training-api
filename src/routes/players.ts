import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const playersRouter = Router()

const createPlayerSchema = z.object({
  passcode: z.string().min(1),
  groupId: z.string().min(1),
  nickname: z.string().min(1),
})

const updatePlayerSchema = createPlayerSchema
const deletePlayerSchema = z.object({ passcode: z.string().min(1) })

const rateSchema = z.object({
  passcode: z.string().min(1),
  planId: z.string().min(1),
  categoryId: z.string().min(1),
  rating: z.number().int().min(1).max(3),
})

playersRouter.get('/', async (req, res) => {
  const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : undefined
  let query = supabase.from('players').select('*').order('nickname')
  if (groupId) query = query.eq('group_id', groupId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

playersRouter.post('/', async (req, res) => {
  const body = createPlayerSchema.parse(req.body)
  const { data, error } = await supabase.rpc('create_player', {
    passcode: body.passcode,
    p_group_id: body.groupId,
    p_nickname: body.nickname,
  })
  if (error) throw new ApiError(error.message === 'invalid passcode' ? 401 : 500, error.message)
  res.status(201).json(data)
})

playersRouter.put('/:id', async (req, res) => {
  const body = updatePlayerSchema.parse(req.body)
  const { data, error } = await supabase.rpc('update_player', {
    passcode: body.passcode,
    p_id: req.params.id,
    p_group_id: body.groupId,
    p_nickname: body.nickname,
  })
  if (error) {
    if (error.message === 'invalid passcode') throw new ApiError(401, error.message)
    if (error.message === 'Player not found') throw new ApiError(404, error.message)
    throw new ApiError(500, error.message)
  }
  res.json(data)
})

playersRouter.delete('/:id', async (req, res) => {
  const body = deletePlayerSchema.parse(req.body)
  const { error } = await supabase.rpc('delete_player', { passcode: body.passcode, p_id: req.params.id })
  if (error) {
    if (error.message === 'invalid passcode') throw new ApiError(401, error.message)
    if (error.message === 'Player not found') throw new ApiError(404, error.message)
    throw new ApiError(500, error.message)
  }
  res.status(204).send()
})

// One rating per (player, plan, category) — trainer taps a category's rating during/after a
// training; re-tapping the same training+category just overwrites it (see rate_player's
// on-conflict upsert in schema.sql).
playersRouter.get('/:id/progress', async (req, res) => {
  const { data, error } = await supabase
    .from('player_progress_ratings')
    .select('*')
    .eq('player_id', req.params.id)
    .order('created_at')
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

playersRouter.post('/:id/progress', async (req, res) => {
  const body = rateSchema.parse(req.body)
  const { data, error } = await supabase.rpc('rate_player', {
    passcode: body.passcode,
    p_player_id: req.params.id,
    p_plan_id: body.planId,
    p_category_id: body.categoryId,
    p_rating: body.rating,
  })
  if (error) {
    if (error.message === 'invalid passcode') throw new ApiError(401, error.message)
    if (error.message === 'Player not found') throw new ApiError(404, error.message)
    throw new ApiError(500, error.message)
  }
  res.status(201).json(data)
})
