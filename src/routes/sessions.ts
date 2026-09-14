import { Router } from 'express'
import { z } from 'zod'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const sessionsRouter = Router()

type SessionStatus = 'idle' | 'running' | 'paused'

interface LiveSessionRow {
  group_id: string
  status: SessionStatus
  elapsed_seconds: number
  running_since: string | null
  updated_at: string
}

/** The clock keeps ticking server-side while running, so live elapsed time is derived, not stored. */
function liveElapsedSeconds(row: LiveSessionRow): number {
  if (row.status !== 'running' || !row.running_since) return row.elapsed_seconds
  const extra = Math.max(0, Math.floor((Date.now() - new Date(row.running_since).getTime()) / 1000))
  return row.elapsed_seconds + extra
}

function serialize(row: LiveSessionRow) {
  return {
    groupId: row.group_id,
    status: row.status,
    elapsedSeconds: liveElapsedSeconds(row),
    updatedAt: row.updated_at,
  }
}

async function getRow(groupId: string): Promise<LiveSessionRow> {
  const { data, error } = await supabase
    .from('live_sessions')
    .select('*')
    .eq('group_id', groupId)
    .maybeSingle()
  if (error) throw new ApiError(500, error.message)
  return (
    data ?? {
      group_id: groupId,
      status: 'idle',
      elapsed_seconds: 0,
      running_since: null,
      updated_at: new Date().toISOString(),
    }
  )
}

async function upsert(row: Pick<LiveSessionRow, 'group_id' | 'status' | 'elapsed_seconds' | 'running_since'>) {
  const { data, error } = await supabase
    .from('live_sessions')
    .upsert({ ...row, updated_at: new Date().toISOString() })
    .select()
    .single()
  if (error) throw new ApiError(500, error.message)
  return data as LiveSessionRow
}

async function assertValidPasscode(groupId: string, passcode: string) {
  const { data, error } = await supabase.rpc('verify_passcode', { p_group_id: groupId, input: passcode })
  if (error) throw new ApiError(500, error.message)
  if (!data) throw new ApiError(401, 'Invalid passcode')
}

const passcodeSchema = z.object({ passcode: z.string().min(1) })
const seekSchema = z.object({ passcode: z.string().min(1), seconds: z.number().int().min(0) })

sessionsRouter.get('/:groupId', async (req, res) => {
  const row = await getRow(req.params.groupId)
  res.json(serialize(row))
})

sessionsRouter.post('/:groupId/start', async (req, res) => {
  const body = passcodeSchema.parse(req.body)
  await assertValidPasscode(req.params.groupId, body.passcode)
  const current = await getRow(req.params.groupId)
  if (current.status === 'running') {
    res.json(serialize(current))
    return
  }
  const row = await upsert({
    group_id: req.params.groupId,
    status: 'running',
    elapsed_seconds: liveElapsedSeconds(current),
    running_since: new Date().toISOString(),
  })
  res.json(serialize(row))
})

sessionsRouter.post('/:groupId/pause', async (req, res) => {
  const body = passcodeSchema.parse(req.body)
  await assertValidPasscode(req.params.groupId, body.passcode)
  const current = await getRow(req.params.groupId)
  const row = await upsert({
    group_id: req.params.groupId,
    status: 'paused',
    elapsed_seconds: liveElapsedSeconds(current),
    running_since: null,
  })
  res.json(serialize(row))
})

sessionsRouter.post('/:groupId/seek', async (req, res) => {
  const body = seekSchema.parse(req.body)
  await assertValidPasscode(req.params.groupId, body.passcode)
  const current = await getRow(req.params.groupId)
  const row = await upsert({
    group_id: req.params.groupId,
    status: current.status === 'idle' ? 'paused' : current.status,
    elapsed_seconds: body.seconds,
    running_since: current.status === 'running' ? new Date().toISOString() : null,
  })
  res.json(serialize(row))
})

sessionsRouter.post('/:groupId/reset', async (req, res) => {
  const body = passcodeSchema.parse(req.body)
  await assertValidPasscode(req.params.groupId, body.passcode)
  const row = await upsert({
    group_id: req.params.groupId,
    status: 'idle',
    elapsed_seconds: 0,
    running_since: null,
  })
  res.json(serialize(row))
})
