import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const plansRouter = Router()

const createPlanSchema = z.object({
  passcode: z.string().min(1),
  groupId: z.string().min(1),
  trainingDate: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'trainingDate must be YYYY-MM-DD'),
  title: z.string().min(1),
  emoji: z.string().min(1),
  exerciseIds: z.array(z.string()),
})

const updatePlanSchema = createPlanSchema.omit({ groupId: true })

const deletePlanSchema = z.object({
  passcode: z.string().min(1),
})

async function assertValidPasscode(groupId: string, passcode: string) {
  const { data, error } = await supabase.rpc('verify_passcode', { p_group_id: groupId, input: passcode })
  if (error) throw new ApiError(500, error.message)
  if (!data) throw new ApiError(401, 'Invalid passcode')
}

/** update/delete only get a plan id from the route — resolve which group's passcode gates it. */
async function groupIdForPlan(id: string): Promise<string> {
  const { data, error } = await supabase.from('plans').select('group_id').eq('id', id).maybeSingle()
  if (error) throw new ApiError(500, error.message)
  if (!data) throw new ApiError(404, 'Plan not found')
  return data.group_id as string
}

plansRouter.get('/', async (req, res) => {
  const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : undefined
  let query = supabase.from('plans').select('*').order('training_date')
  if (groupId) query = query.eq('group_id', groupId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)
  res.json(data)
})

plansRouter.post('/', async (req, res) => {
  const body = createPlanSchema.parse(req.body)
  await assertValidPasscode(body.groupId, body.passcode)

  const { data, error } = await supabase
    .from('plans')
    .insert({
      group_id: body.groupId,
      training_date: body.trainingDate,
      title: body.title,
      emoji: body.emoji,
      exercise_ids: body.exerciseIds,
    })
    .select()
    .single()

  if (error) {
    if (error.code === '23505') {
      throw new ApiError(409, 'This group already has a training planned on that date')
    }
    throw new ApiError(500, error.message)
  }
  res.status(201).json(data)
})

plansRouter.put('/:id', async (req, res) => {
  const body = updatePlanSchema.parse(req.body)
  await assertValidPasscode(await groupIdForPlan(req.params.id), body.passcode)

  const { data, error } = await supabase
    .from('plans')
    .update({
      training_date: body.trainingDate,
      title: body.title,
      emoji: body.emoji,
      exercise_ids: body.exerciseIds,
      updated_at: new Date().toISOString(),
    })
    .eq('id', req.params.id)
    .select()
    .maybeSingle()

  if (error) {
    if (error.code === '23505') {
      throw new ApiError(409, 'This group already has a training planned on that date')
    }
    throw new ApiError(500, error.message)
  }
  if (!data) throw new ApiError(404, 'Plan not found')
  res.json(data)
})

plansRouter.delete('/:id', async (req, res) => {
  const body = deletePlanSchema.parse(req.body)
  await assertValidPasscode(await groupIdForPlan(req.params.id), body.passcode)

  const { error } = await supabase.from('plans').delete().eq('id', req.params.id)
  if (error) throw new ApiError(500, error.message)
  res.status(204).send()
})
