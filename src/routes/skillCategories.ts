import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const skillCategoriesRouter = Router()

// The *rateable* taxonomy a player's progress is scored against — deliberately its own table
// and endpoint, separate from GET /categories (which serves `exercise_categories`, the
// *training-content* taxonomy that includes 'warmup'). `parent_id` lets a finer sub-skill (e.g.
// 'dribbling_strong_hand') group under its parent ('dribbling') in the UI. Public read, no
// passcode — this is reference content, not a club's own data.
skillCategoriesRouter.get('/', async (req, res) => {
  const sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  let query = supabase.from('skill_categories').select('*').order('sort_order')
  if (sportId) query = query.eq('sport_id', sportId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
