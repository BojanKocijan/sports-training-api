import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const categoriesRouter = Router()

// Exercise/training categories (see exercise_categories — deliberately separate from the
// rateable `skill_categories`, which excludes 'warmup'). Public read, no passcode.
categoriesRouter.get('/', async (req, res) => {
  const sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  let query = supabase.from('exercise_categories').select('*').order('sort_order')
  if (sportId) query = query.eq('sport_id', sportId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
