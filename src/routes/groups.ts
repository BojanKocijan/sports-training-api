import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const groupsRouter = Router()

// Never select `passcode` here — this is the public group list for the UI's group selector.
groupsRouter.get('/', async (_req, res) => {
  const { data, error } = await supabase
    .from('groups')
    .select('id, club_id, template_id, name, created_at, group_templates(label, emoji, status)')
    .order('created_at')
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

// Every progress rating logged for every player currently in this group, across every
// training — raw rows, not pre-aggregated, so the UI decides the actual rollup/trend shape
// (weekly averages, most/least-trained category, etc.) rather than the API guessing it.
// `players!inner` forces the join so .eq('players.group_id', ...) actually filters rows,
// per PostgREST's embedded-resource filtering rules.
groupsRouter.get('/:id/progress', async (req, res) => {
  const { data, error } = await supabase
    .from('player_progress_ratings')
    .select('rating, created_at, players!inner(id, nickname, group_id), skill_categories(id, label, emoji)')
    .eq('players.group_id', req.params.id)
    .order('created_at')
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
