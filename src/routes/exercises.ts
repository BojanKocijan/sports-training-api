import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const exercisesRouter = Router()

// Public read, no passcode — this is shared reference content (the training library), not a
// club's own data. `sportId` narrows it the same way group_templates/skill_categories do.
exercisesRouter.get('/', async (req, res) => {
  const sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  let query = supabase.from('exercises').select('*').order('sort_order')
  if (sportId) query = query.eq('sport_id', sportId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
