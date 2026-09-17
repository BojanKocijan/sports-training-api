import { Router } from 'express'
import { supabase } from '../lib/supabaseClient.js'
import { ApiError } from '../middleware/errorHandler.js'

export const skillCategoriesRouter = Router()

// The *rateable* taxonomy a player's progress is scored against — deliberately its own table
// and endpoint, separate from GET /categories (which serves `exercise_categories`, the
// *training-content* taxonomy that includes 'warmup'). `parent_id` lets a finer sub-skill (e.g.
// 'dribbling_strong_hand') group under its parent ('dribbling') in the UI. Public read, no
// passcode — this is reference content, not a club's own data.
//
// `skill_category_groups` optionally scopes a category to specific group templates (age
// bands). A category with no rows there applies to every group, so `groupTemplateIds` comes
// back empty for it — `?groupId=` only excludes categories that are explicitly scoped to a
// *different* group.
skillCategoriesRouter.get('/', async (req, res) => {
  const sportId = typeof req.query.sportId === 'string' ? req.query.sportId : undefined
  const groupId = typeof req.query.groupId === 'string' ? req.query.groupId : undefined

  let query = supabase
    .from('skill_categories')
    .select('*, skill_category_groups(group_template_id)')
    .order('sort_order')
  if (sportId) query = query.eq('sport_id', sportId)

  const { data, error } = await query
  if (error) throw new ApiError(500, error.message)

  const categories = (data ?? []).map(({ skill_category_groups, ...category }) => ({
    ...category,
    groupTemplateIds: (skill_category_groups as { group_template_id: string }[]).map(
      (row) => row.group_template_id
    ),
  }))

  const result = groupId
    ? categories.filter((c) => c.groupTemplateIds.length === 0 || c.groupTemplateIds.includes(groupId))
    : categories

  res.json(result)
})
