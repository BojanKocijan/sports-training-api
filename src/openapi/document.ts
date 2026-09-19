import './zodExtend.js'

import { OpenApiGeneratorV31, OpenAPIRegistry } from '@asteasolutions/zod-to-openapi'
import { z } from 'zod'
import { verifyPasscodeSchema } from '../routes/auth.js'
import { createPlanSchema, deletePlanSchema, updatePlanSchema } from '../routes/plans.js'
import {
  createPlayerSchema,
  deletePlayerSchema,
  parentCodeSchema,
  rateSchema,
  updatePlayerSchema,
} from '../routes/players.js'
import { passcodeSchema, seekSchema } from '../routes/sessions.js'

const registry = new OpenAPIRegistry()

const ErrorSchema = z.object({ error: z.string() }).openapi('Error')

function errorResponses(...statuses: number[]) {
  return Object.fromEntries(
    statuses.map((status) => [
      status,
      { description: errorDescription(status), content: { 'application/json': { schema: ErrorSchema } } },
    ]),
  )
}

function errorDescription(status: number): string {
  switch (status) {
    case 400:
      return 'Invalid request'
    case 401:
      return 'Invalid passcode'
    case 404:
      return 'Not found'
    case 409:
      return 'Conflict (e.g. a training already exists on that date)'
    default:
      return 'Unexpected error'
  }
}

function jsonResponse(description: string, schema: z.ZodTypeAny) {
  return { description, content: { 'application/json': { schema } } }
}

function noStoreJsonResponse(description: string, schema: z.ZodTypeAny) {
  return {
    ...jsonResponse(description, schema),
    headers: z.object({
      'Cache-Control': z.literal('no-store').openapi({
        description: 'Prevents access credentials from being stored by clients or intermediaries',
      }),
    }),
  }
}

// ---------------------------------------------------------------------------
// Shared resource shapes -- mirror what the route handlers actually select/return, not the full
// table (e.g. players never returns parent_code; groups list returns a joined shape).
// ---------------------------------------------------------------------------

const PlayerSchema = z
  .object({
    id: z.string(),
    group_id: z.string(),
    nickname: z.string(),
    jersey_number: z.number().int().nullable(),
    jersey_color: z.string().nullable(),
    height_cm: z.number().int().nullable(),
    weight_kg: z.number().int().nullable(),
    mascot_id: z.string().nullable(),
    created_at: z.string(),
    updated_at: z.string(),
  })
  .openapi('Player')

const PlanSchema = z
  .object({
    id: z.string(),
    group_id: z.string(),
    training_date: z.string().openapi({ example: '2026-09-20' }),
    title: z.string(),
    emoji: z.string(),
    exercise_ids: z.array(z.string()),
    created_at: z.string(),
    updated_at: z.string(),
  })
  .openapi('Plan')

const GroupListItemSchema = z
  .object({
    id: z.string(),
    template_id: z.string(),
    name: z.string(),
    created_at: z.string().nullable(),
    group_templates: z.object({
      label: z.string(),
      emoji: z.string(),
      status: z.enum(['available', 'coming_soon']),
    }),
  })
  .openapi('GroupListItem')

const GroupProgressRowSchema = z
  .object({
    rating: z.number().int().min(1).max(3),
    created_at: z.string(),
    players: z.object({ id: z.string(), nickname: z.string(), group_id: z.string() }),
    plans: z.object({ id: z.string(), group_id: z.string() }),
    skill_categories: z.object({ id: z.string(), label: z.string(), emoji: z.string() }).nullable(),
  })
  .openapi('GroupProgressRow')

const ClubSchema = z
  .object({
    id: z.string(),
    slug: z.string(),
    name: z.string(),
    logo_url: z.string().nullable(),
    sport_subscription_id: z.string().nullable(),
    created_at: z.string(),
  })
  .openapi('Club')

const ExerciseCategorySchema = z
  .object({
    id: z.string(),
    sport_id: z.string(),
    label: z.string(),
    emoji: z.string(),
    sort_order: z.number().int(),
  })
  .openapi('ExerciseCategory')

const ExerciseSchema = z
  .object({
    id: z.string(),
    sport_id: z.string(),
    title: z.string(),
    emoji: z.string(),
    subtitle: z.string().nullable(),
    duration_minutes: z.number().int(),
    goal: z.string(),
    steps: z.array(z.string()),
    cues: z.array(z.record(z.string(), z.string())).nullable(),
    is_break: z.boolean(),
    categories: z.array(z.string()),
    groups: z.array(z.string()).nullable(),
  })
  .openapi('Exercise')

const SkillCategorySchema = z
  .object({
    id: z.string(),
    sport_id: z.string(),
    label: z.string(),
    emoji: z.string(),
    sort_order: z.number().int(),
    parent_id: z.string().nullable(),
    groupTemplateIds: z.array(z.string()),
  })
  .openapi('SkillCategory')

const MascotSchema = z
  .object({ id: z.string(), name: z.string(), sort_order: z.number().int() })
  .openapi('Mascot')

const MascotAvatarSchema = z
  .object({
    id: z.string(),
    mascot_id: z.string(),
    sport_id: z.string(),
    stage: z.string(),
    jersey_color: z.string().nullable(),
    image_url: z.string(),
  })
  .openapi('MascotAvatar')

const ProgressRatingSchema = z
  .object({
    id: z.string(),
    player_id: z.string(),
    plan_id: z.string(),
    category_id: z.string(),
    rating: z.number().int().min(1).max(3),
    created_at: z.string(),
  })
  .openapi('ProgressRating')

const LiveSessionSchema = z
  .object({
    groupId: z.string(),
    status: z.enum(['idle', 'running', 'paused']),
    elapsedSeconds: z.number().int(),
    updatedAt: z.string(),
  })
  .openapi('LiveSession')

const VerifyPasscodeResultSchema = z
  .object({
    valid: z.boolean(),
    kind: z.enum(['trainer', 'parent']).optional(),
    player: z.object({ id: z.string(), nickname: z.string() }).optional(),
  })
  .openapi('VerifyPasscodeResult')

const ParentCodeResultSchema = z.object({ parentCode: z.string().nullable() }).openapi('ParentCodeResult')

const GroupIdParam = z.object({ groupId: z.string().openapi({ example: 'u10' }) })
const IdParam = z.object({ id: z.string() })

// ---------------------------------------------------------------------------
// auth
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'post',
  path: '/auth/verify-passcode',
  tags: ['Auth'],
  summary: 'Resolve a group + code into trainer access, parent access, or no match',
  request: { body: { content: { 'application/json': { schema: verifyPasscodeSchema } } } },
  responses: { 200: jsonResponse('Verification result', VerifyPasscodeResultSchema) },
})

// ---------------------------------------------------------------------------
// clubs
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/clubs',
  tags: ['Clubs'],
  summary: 'List every club',
  responses: { 200: jsonResponse('Clubs', z.array(ClubSchema)) },
})

registry.registerPath({
  method: 'get',
  path: '/clubs/{slug}',
  tags: ['Clubs'],
  summary: 'Get a club by slug',
  request: { params: z.object({ slug: z.string() }) },
  responses: { 200: jsonResponse('Club', ClubSchema), ...errorResponses(404) },
})

// ---------------------------------------------------------------------------
// categories (exercise_categories)
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/categories',
  tags: ['Categories'],
  summary: 'List exercise/training categories',
  request: { query: z.object({ sportId: z.string().optional() }) },
  responses: { 200: jsonResponse('Exercise categories', z.array(ExerciseCategorySchema)) },
})

// ---------------------------------------------------------------------------
// skill-categories
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/skill-categories',
  tags: ['Skill Categories'],
  summary: 'List the rateable skill taxonomy, optionally scoped to a group',
  request: { query: z.object({ sportId: z.string().optional(), groupId: z.string().optional() }) },
  responses: { 200: jsonResponse('Skill categories', z.array(SkillCategorySchema)) },
})

// ---------------------------------------------------------------------------
// exercises
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/exercises',
  tags: ['Exercises'],
  summary: 'List the training exercise library',
  request: { query: z.object({ sportId: z.string().optional() }) },
  responses: { 200: jsonResponse('Exercises', z.array(ExerciseSchema)) },
})

// ---------------------------------------------------------------------------
// groups
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/groups',
  tags: ['Groups'],
  summary: "List every group template, joined with the club's own group where one exists",
  responses: { 200: jsonResponse('Groups', z.array(GroupListItemSchema)) },
})

registry.registerPath({
  method: 'get',
  path: '/groups/{id}/progress',
  tags: ['Groups'],
  summary: 'Every progress rating recorded on a training plan belonging to this group',
  request: { params: IdParam },
  responses: { 200: jsonResponse('Progress rows', z.array(GroupProgressRowSchema)) },
})

// ---------------------------------------------------------------------------
// mascots
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/mascots',
  tags: ['Mascots'],
  summary: 'List the global mascot roster',
  responses: { 200: jsonResponse('Mascots', z.array(MascotSchema)) },
})

registry.registerPath({
  method: 'get',
  path: '/mascots/avatars',
  tags: ['Mascots'],
  summary:
    'List sport/stage-scoped mascot artwork. Pass groupId to resolve sport+stage from the group’s own age range, or sportId/stage directly.',
  request: {
    query: z.object({
      groupId: z.string().optional(),
      sportId: z.string().optional(),
      stage: z.string().optional(),
    }),
  },
  responses: { 200: jsonResponse('Mascot avatars (empty if this stage has no art yet)', z.array(MascotAvatarSchema)) },
})

// ---------------------------------------------------------------------------
// plans
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/plans',
  tags: ['Plans'],
  summary: "List a group's shared, dated training plans",
  request: { query: z.object({ groupId: z.string().optional() }) },
  responses: { 200: jsonResponse('Plans', z.array(PlanSchema)) },
})

registry.registerPath({
  method: 'post',
  path: '/plans',
  tags: ['Plans'],
  summary: 'Create a training plan (passcode-gated)',
  request: { body: { content: { 'application/json': { schema: createPlanSchema } } } },
  responses: { 201: jsonResponse('Created plan', PlanSchema), ...errorResponses(401, 409) },
})

registry.registerPath({
  method: 'put',
  path: '/plans/{id}',
  tags: ['Plans'],
  summary: 'Update a training plan (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: updatePlanSchema } } } },
  responses: { 200: jsonResponse('Updated plan', PlanSchema), ...errorResponses(401, 404, 409) },
})

registry.registerPath({
  method: 'delete',
  path: '/plans/{id}',
  tags: ['Plans'],
  summary: 'Delete a training plan (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: deletePlanSchema } } } },
  responses: { 204: { description: 'Deleted' }, ...errorResponses(401, 404) },
})

// ---------------------------------------------------------------------------
// players
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/players',
  tags: ['Players'],
  summary: "List a group's roster (never includes parent_code)",
  request: { query: z.object({ groupId: z.string().optional() }) },
  responses: { 200: jsonResponse('Players', z.array(PlayerSchema)) },
})

registry.registerPath({
  method: 'post',
  path: '/players',
  tags: ['Players'],
  summary: 'Add a player to a group (passcode-gated)',
  request: { body: { content: { 'application/json': { schema: createPlayerSchema } } } },
  responses: { 201: jsonResponse('Created player', PlayerSchema), ...errorResponses(401) },
})

registry.registerPath({
  method: 'put',
  path: '/players/{id}',
  tags: ['Players'],
  summary: 'Update a player, optionally moving them to a different group (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: updatePlayerSchema } } } },
  responses: { 200: jsonResponse('Updated player', PlayerSchema), ...errorResponses(401, 404) },
})

registry.registerPath({
  method: 'delete',
  path: '/players/{id}',
  tags: ['Players'],
  summary: 'Remove a player (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: deletePlayerSchema } } } },
  responses: { 204: { description: 'Deleted' }, ...errorResponses(401, 404) },
})

registry.registerPath({
  method: 'get',
  path: '/players/{id}/progress',
  tags: ['Players'],
  summary: "A player's own rating history, across every training",
  request: { params: IdParam },
  responses: { 200: jsonResponse('Ratings', z.array(ProgressRatingSchema)) },
})

registry.registerPath({
  method: 'post',
  path: '/players/{id}/progress',
  tags: ['Players'],
  summary: 'Rate a player on one skill category for a specific training (passcode-gated, upserts)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: rateSchema } } } },
  responses: { 201: jsonResponse('Rating', ProgressRatingSchema), ...errorResponses(401, 404) },
})

registry.registerPath({
  method: 'post',
  path: '/players/{id}/parent-code/read',
  tags: ['Players'],
  summary: "Read a player's current parent code (trainer passcode in request body)",
  request: { params: IdParam, body: { content: { 'application/json': { schema: parentCodeSchema } } } },
  responses: {
    200: noStoreJsonResponse('Parent code (null if none set)', ParentCodeResultSchema),
    ...errorResponses(400, 401, 404),
  },
})

registry.registerPath({
  method: 'post',
  path: '/players/{id}/parent-code',
  tags: ['Players'],
  summary: 'Issue a fresh parent code, revoking any existing one (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: parentCodeSchema } } } },
  responses: {
    200: noStoreJsonResponse('New parent code', ParentCodeResultSchema),
    ...errorResponses(401, 404),
  },
})

registry.registerPath({
  method: 'delete',
  path: '/players/{id}/parent-code',
  tags: ['Players'],
  summary: 'Revoke a parent code without issuing a new one (passcode-gated)',
  request: { params: IdParam, body: { content: { 'application/json': { schema: parentCodeSchema } } } },
  responses: { 204: { description: 'Revoked' }, ...errorResponses(401, 404) },
})

// ---------------------------------------------------------------------------
// sessions (the live training clock)
// ---------------------------------------------------------------------------

registry.registerPath({
  method: 'get',
  path: '/sessions/{groupId}',
  tags: ['Sessions'],
  summary: "A group's live session clock (idle if none has ever been started)",
  request: { params: GroupIdParam },
  responses: { 200: jsonResponse('Live session', LiveSessionSchema) },
})

registry.registerPath({
  method: 'post',
  path: '/sessions/{groupId}/start',
  tags: ['Sessions'],
  summary: 'Start (or resume) the clock (passcode-gated)',
  request: { params: GroupIdParam, body: { content: { 'application/json': { schema: passcodeSchema } } } },
  responses: { 200: jsonResponse('Live session', LiveSessionSchema), ...errorResponses(401) },
})

registry.registerPath({
  method: 'post',
  path: '/sessions/{groupId}/pause',
  tags: ['Sessions'],
  summary: 'Pause the clock (passcode-gated)',
  request: { params: GroupIdParam, body: { content: { 'application/json': { schema: passcodeSchema } } } },
  responses: { 200: jsonResponse('Live session', LiveSessionSchema), ...errorResponses(401) },
})

registry.registerPath({
  method: 'post',
  path: '/sessions/{groupId}/seek',
  tags: ['Sessions'],
  summary: 'Jump the clock to a specific elapsed-seconds value (passcode-gated)',
  request: { params: GroupIdParam, body: { content: { 'application/json': { schema: seekSchema } } } },
  responses: { 200: jsonResponse('Live session', LiveSessionSchema), ...errorResponses(401) },
})

registry.registerPath({
  method: 'post',
  path: '/sessions/{groupId}/reset',
  tags: ['Sessions'],
  summary: 'Reset the clock to idle/zero (passcode-gated)',
  request: { params: GroupIdParam, body: { content: { 'application/json': { schema: passcodeSchema } } } },
  responses: { 200: jsonResponse('Live session', LiveSessionSchema), ...errorResponses(401) },
})

// ---------------------------------------------------------------------------

export function generateOpenApiDocument() {
  const generator = new OpenApiGeneratorV31(registry.definitions)
  return generator.generateDocument({
    openapi: '3.1.0',
    info: {
      title: 'sports-training-api',
      version: '0.0.0',
      description:
        'Server-side API for the U8 Basketball Training app. Every write route is gated by a ' +
        "group's own passcode (trainer or parent) instead of a login -- see /auth/verify-passcode.",
    },
    servers: [{ url: '/' }],
  })
}
