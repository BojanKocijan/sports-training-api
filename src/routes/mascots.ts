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
// both optional filters for a caller that already knows both. `?groupId=` is for a caller that
// only knows the group — it resolves sport + stage server-side from the group's own sport_id
// and age (see #45/#72/#49): age is what determines a group's stage, not its name or template,
// since clubs can rename groups or create custom ones with no template at all.
mascotsRouter.get('/avatars', async (req, res) => {
  let sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  let stage = typeof req.query.stage === 'string' ? req.query.stage : undefined
  const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : undefined

  if (groupId) {
    const { data: group, error: groupError } = await supabase
      .from('groups')
      .select('sport_id, min_age')
      .eq('id', groupId)
      .maybeSingle()
    if (groupError) throw new ApiError(500, groupError.message)

    // No group, or no age set yet -- nothing to resolve. Not an error: a group without an age
    // band just has no mascot art match, same shape as any other "no rows" response.
    if (!group || group.min_age === null) {
      res.json([])
      return
    }

    const { data: stageRow, error: stageError } = await supabase
      .from('mascot_stages')
      .select('id')
      .lte('min_age', group.min_age)
      .or(`max_age.is.null,max_age.gt.${group.min_age}`)
      .order('min_age', { ascending: false })
      .limit(1)
      .maybeSingle()
    if (stageError) throw new ApiError(500, stageError.message)

    if (!stageRow) {
      res.json([])
      return
    }

    sportId = group.sport_id
    stage = stageRow.id
  }

  let query = supabase.from('mascot_avatars').select('*').order('mascot_id')
  if (sportId) query = query.eq('sport_id', sportId)
  if (stage) query = query.eq('stage', stage)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
