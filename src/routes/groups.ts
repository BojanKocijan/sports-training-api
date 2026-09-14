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
