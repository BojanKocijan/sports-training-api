import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const authRouter = Router()

const verifyPasscodeSchema = z.object({
  groupId: z.string().min(1),
  passcode: z.string().min(1),
})

authRouter.post('/verify-passcode', async (req, res) => {
  const body = verifyPasscodeSchema.parse(req.body)
  const { data, error } = await supabase.rpc('verify_passcode', {
    p_group_id: body.groupId,
    input: body.passcode,
  })
  if (error) throw new ApiError(500, error.message)
  res.json({ valid: Boolean(data) })
})
