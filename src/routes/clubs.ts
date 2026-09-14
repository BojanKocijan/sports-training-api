import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const clubsRouter = Router()

clubsRouter.get('/', async (_req, res) => {
  const { data, error } = await supabase.from('clubs').select('*').order('name')
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

clubsRouter.get('/:slug', async (req, res) => {
  const { data, error } = await supabase
    .from('clubs')
    .select('*')
    .eq('slug', req.params.slug)
    .maybeSingle()
  if (error) throw new ApiError(500, error.message)
  if (!data) throw new ApiError(404, 'Club not found')
  res.json(data)
})
