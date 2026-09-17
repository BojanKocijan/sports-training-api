import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const groupsRouter = Router()

// Never select `passcode` here — this is the public group list for the UI's group selector.
// Returns the FULL group_templates catalog (not just templates the club already has a `groups`
// row for), so 'coming_soon' age bands like U12/U14 show up as upcoming rather than not existing
// at all — the UI (GroupMenu, LockScreen) already knows how to render a disabled "coming soon"
// entry, it just never received one for a template with no club instance yet.
groupsRouter.get('/', async (_req, res) => {
  const [templatesResult, groupsResult] = await Promise.all([
    supabase
      .from('group_templates')
      .select('id, label, emoji, status')
      .order('sort_order'),
    supabase
      .from('groups')
      .select('id, template_id, name, created_at')
      .order('created_at'),
  ])

  if (templatesResult.error)
    throw new ApiError(500, templatesResult.error.message)
  if (groupsResult.error) throw new ApiError(500, groupsResult.error.message)

  const groupByTemplateId = new Map(
    groupsResult.data.map((g) => [g.template_id, g]),
  )

  const result = templatesResult.data.map((template) => {
    const group = groupByTemplateId.get(template.id)

    return {
      // A template without a club `groups` row yet (coming soon) has no real group id — the
      // template id doubles as a stand-in; it's never selectable since status !== 'available'.
      id: group?.id ?? template.id,
      template_id: template.id,
      name: group?.name ?? template.label,
      created_at: group?.created_at ?? null,
      group_templates: {
        label: template.label,
        emoji: template.emoji,
        status: template.status,
      },
    }
  })

  res.json(result)
})

// Every progress rating recorded on a training plan belonging to this group.
// Group history follows the plan where the rating was recorded, not the player's CURRENT group,
// so promoting a player from U8 to U10 does not move their historical U8 ratings into U10.
groupsRouter.get('/:id/progress', async (req, res) => {
  const { data, error } = await supabase
    .from('player_progress_ratings')
    .select(
      'rating, created_at, players!inner(id, nickname, group_id), plans!inner(id, group_id), skill_categories(id, label, emoji)',
    )
    .eq('plans.group_id', req.params.id)
    .order('created_at')

  if (error) throw new ApiError(500, error.message)
  res.json(data)
})
