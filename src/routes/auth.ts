import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const authRouter = Router()

export const verifyPasscodeSchema = z.object({
  groupId: z.string().min(1),
  passcode: z.string().min(1),
})

// Resolves a group + code into one of: no match, the group's trainer passcode, or a specific
// player's parent code (see verify_group_access — sports-training-api#20). The UI branches on
// `kind` to render full trainer access vs. a read-only single-child parent view.
authRouter.post('/verify-passcode', async (req, res) => {
  const body = verifyPasscodeSchema.parse(req.body)
  const { data, error } = await supabase.rpc('verify_group_access', {
    p_group_id: body.groupId,
    input: body.passcode,
  })
  if (error) throw new ApiError(500, error.message)
  const match = data?.[0]
  if (!match) {
    res.json({ valid: false })
    return
  }
  if (match.kind === 'trainer') {
    res.json({ valid: true, kind: 'trainer' })
    return
  }
  res.json({
    valid: true,
    kind: 'parent',
    player: { id: match.player_id, nickname: match.player_nickname },
  })
})
