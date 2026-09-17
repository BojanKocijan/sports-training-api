import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const mascotsRouter = Router()

// The animal roster a player picks their avatar from (see sports-training-api#43). Global,
// not sport-scoped — the same lion follows a player if their club adds a second sport later.
// Public read, no passcode — this is reference content, not a club's own data.
mascotsRouter.get('/', async (_req, res) => {
  const { data, error } = await supabase.from('mascots').select('*').order('sort_order')
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

// Sport-scoped, life-stage-scoped artwork for the roster above. `?sportId=` and `?stage=` are
// both optional filters — a caller that already knows a player's group can resolve `stage`
// from `group_templates.mascot_stage` and pass both to get exactly the art it needs.
mascotsRouter.get('/avatars', async (req, res) => {
  const sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  const stage = typeof req.query.stage === 'string' ? req.query.stage : undefined

  let query = supabase.from('mascot_avatars').select('*').order('mascot_id')
  if (sportId) query = query.eq('sport_id', sportId)
  if (stage) query = query.eq('stage', stage)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
