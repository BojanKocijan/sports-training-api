import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const playersRouter = Router()

// Must match the `players.jersey_color` check constraint in supabase/schema.sql.
const JERSEY_COLORS = ['orange', 'blue', 'red', 'green', 'purple', 'black', 'white', 'yellow'] as const
// Must match the `players.eye_color` check constraint -- the 3 eye-color masks actually
// produced in Figma for the dynamic 'baby'-stage art (sports-training-api#57/#59).
const EYE_COLORS = ['blue', 'green', 'brown'] as const

export const createPlayerSchema = z.object({
  passcode: z.string().min(1),
  groupId: z.string().min(1),
  nickname: z.string().min(1),
  jerseyNumber: z.number().int().min(0).max(999).nullish(),
  jerseyColor: z.enum(JERSEY_COLORS).nullish(),
  eyeColor: z.enum(EYE_COLORS).nullish(),
  // Optional bio details — see the players.height_cm/weight_kg check constraints in
  // supabase/schema.sql for the same bounds.
  heightCm: z.number().int().min(50).max(250).nullish(),
  weightKg: z.number().int().min(10).max(200).nullish(),
  // The animal avatar the player picked — see GET /mascots. Free-form FK reference, not an
  // enum here, since the roster grows over time (see supabase/schema.sql `mascots`).
  mascotId: z.string().min(1).nullish(),
})

export const updatePlayerSchema = createPlayerSchema
export const deletePlayerSchema = z.object({ passcode: z.string().min(1) })

export const rateSchema = z.object({
  passcode: z.string().min(1),
  planId: z.string().min(1),
  categoryId: z.string().min(1),
  rating: z.number().int().min(1).max(3),
})

export const parentCodeSchema = z.object({ passcode: z.string().min(1) })

// Unambiguous alphabet — no 0/O or 1/I — since a parent reads this off a piece of paper or a
// phone screen from a trainer, not a password manager.
const CODE_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'

function generateParentCode(): string {
  let code = ''
  for (let i = 0; i < 6; i++) {
    code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)]
  }
  return code
}

// Never select `parent_code` here — it's a secret, same principle as groups.passcode. Its value
// is only ever readable through the passcode-gated GET /:id/parent-code below.
playersRouter.get('/', async (req, res) => {
  const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : undefined
  let query = supabase
    .from('players')
    .select(
      'id, group_id, nickname, jersey_number, jersey_color, eye_color, height_cm, weight_kg, mascot_id, created_at, updated_at'
    )
    .order('nickname')
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
    p_jersey_number: body.jerseyNumber ?? null,
    p_jersey_color: body.jerseyColor ?? null,
    p_height_cm: body.heightCm ?? null,
    p_weight_kg: body.weightKg ?? null,
    p_mascot_id: body.mascotId ?? null,
    p_eye_color: body.eyeColor ?? null,
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
    p_jersey_number: body.jerseyNumber ?? null,
    p_jersey_color: body.jerseyColor ?? null,
    p_height_cm: body.heightCm ?? null,
    p_weight_kg: body.weightKg ?? null,
    p_mascot_id: body.mascotId ?? null,
    p_eye_color: body.eyeColor ?? null,
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

// Passcode-gated read of the current code (or null if none is set) — a trainer can look this up
// any time, not just at the moment it was issued. Passcode travels as a query param since GET
// requests carry no body; these codes are a light convenience secret, not a real credential, so
// that's an acceptable tradeoff here (unlike every other passcode check in this file, which is
// a POST/PUT/DELETE body).
playersRouter.get('/:id/parent-code', async (req, res) => {
  const passcode = typeof req.query.passcode === 'string' ? req.query.passcode : ''
  const body = parentCodeSchema.parse({ passcode })

  const { data: player, error: playerError } = await supabase
    .from('players')
    .select('group_id, parent_code')
    .eq('id', req.params.id)
    .maybeSingle()
  if (playerError) throw new ApiError(500, playerError.message)
  if (!player) throw new ApiError(404, 'Player not found')

  const { data: valid, error: verifyError } = await supabase.rpc('verify_passcode', {
    p_group_id: player.group_id,
    input: body.passcode,
  })
  if (verifyError) throw new ApiError(500, verifyError.message)
  if (!valid) throw new ApiError(401, 'invalid passcode')

  res.json({ parentCode: player.parent_code })
})

// Issues a fresh parent code for this player, overwriting any existing one (so an old code a
// parent had written down stops working the moment a new one is generated — same "issuing a
// new one revokes the old" behavior as a trainer passcode reset).
playersRouter.post('/:id/parent-code', async (req, res) => {
  const body = parentCodeSchema.parse(req.body)

  // Collisions are astronomically unlikely (6 chars from a 33-symbol alphabet) but the unique
  // index means one would fail loudly rather than silently double-assigning a code, so retry
  // a few times rather than surface that as a user-facing error.
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = generateParentCode()
    const { error } = await supabase.rpc('set_player_parent_code', {
      passcode: body.passcode,
      p_id: req.params.id,
      p_code: code,
    })
    if (!error) {
      res.json({ parentCode: code })
      return
    }
    if (error.message === 'invalid passcode') throw new ApiError(401, error.message)
    if (error.message === 'Player not found') throw new ApiError(404, error.message)
    if (error.code !== '23505') throw new ApiError(500, error.message)
    // 23505 = unique_violation on players_parent_code_unique_idx — loop and try a new code.
  }
  throw new ApiError(500, 'Could not generate a unique parent code, try again')
})

playersRouter.delete('/:id/parent-code', async (req, res) => {
  const body = parentCodeSchema.parse(req.body)
  const { error } = await supabase.rpc('set_player_parent_code', {
    passcode: body.passcode,
    p_id: req.params.id,
    p_code: null,
  })
  if (error) {
    if (error.message === 'invalid passcode') throw new ApiError(401, error.message)
    if (error.message === 'Player not found') throw new ApiError(404, error.message)
    throw new ApiError(500, error.message)
  }
  res.status(204).send()
})
