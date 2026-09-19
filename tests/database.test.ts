import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { createTestPostgres } from './helpers/postgres.js'

// Runs the repository's unmodified schema, including the final RPC overloads. HTTP tests
// cover routing; these tests prove that authorization, upserts and history are enforced
// by PostgreSQL itself rather than reimplementing those rules in a JavaScript mock.
const pg = createTestPostgres()
const child = '00000000-0000-4000-8000-000000000001'
const sibling = '00000000-0000-4000-8000-000000000002'
const u8Plan = '00000000-0000-4000-8000-000000000008'
const u10Plan = '00000000-0000-4000-8000-000000000010'
const missing = '00000000-0000-4000-8000-000000000099'

beforeAll(() => pg.start(), 60_000)
afterAll(() => pg.stop(), 30_000)
beforeEach(() => {
  pg.sql(`
    truncate players, plans cascade;
    update groups set passcode = 'u8-trainer' where id = 'u8';
    update groups set passcode = 'u10-trainer' where id = 'u10';
    insert into players (id, group_id, nickname, parent_code, jersey_number, jersey_color, mascot_id, eye_color, gender)
    values ('${child}', 'u8', 'Lion', 'ABC234', 7, 'blue', 'lion', 'green', 'girl'),
           ('${sibling}', 'u8', 'Shark', 'XYZ789', 8, 'red', 'shark', 'brown', 'boy');
    insert into plans (id, group_id, training_date, title, emoji)
    values ('${u8Plan}', 'u8', '2026-09-19', 'U8 practice', '🏀'),
           ('${u10Plan}', 'u10', '2026-09-19', 'U10 practice', '🏀');
  `)
})

function rate(code = 'u8-trainer', plan = u8Plan, category = 'dribbling', rating = 2, player = child) {
  return pg.rows(`select * from rate_player('${code}', '${player}', '${plan}', '${category}', ${rating}::smallint)`)[0]
}

function promote(code = 'u8-trainer', group = 'u10') {
  return pg.rows(`select * from update_player('${code}', '${child}', '${group}', 'Lion', 7, 'blue', 120, 25, 'lion', 'green', 'girl')`)[0]
}

function access(group: string, code: string) {
  return pg.rows(`select * from verify_group_access('${group}', '${code}')`)
}

describe('MUST SQL: trainer, parent and invalid group access', () => {
  it('distinguishes trainer from a parent scoped to one child', () => {
    expect(access('u8', 'u8-trainer')).toEqual([{ kind: 'trainer', player_id: null, player_nickname: null }])
    expect(access('u8', 'ABC234')).toEqual([{ kind: 'parent', player_id: child, player_nickname: 'Lion' }])
    expect(access('u8', 'XYZ789')).toEqual([{ kind: 'parent', player_id: sibling, player_nickname: 'Shark' }])
  })

  it.each([
    ['u8', 'wrong'], ['u8', ''], ['u10', 'u8-trainer'], ['u8', 'u10-trainer'],
    ['u10', 'ABC234'], ['missing', 'u8-trainer'],
  ])('rejects group=%s code=%s', (group, code) => {
    expect(access(group, code)).toEqual([])
    expect(pg.sql(`select verify_passcode('${group}', '${code}')`)).toBe('f')
  })

  it('a valid parent code never passes the trainer-only verifier', () => {
    expect(pg.sql("select verify_passcode('u8', 'ABC234')")).toBe('f')
    expect(pg.sql("select verify_passcode('u8', 'u8-trainer')")).toBe('t')
  })
})

describe('MUST SQL: player mutations and authorization', () => {
  it('creates, updates and deletes a player with the correct group code', () => {
    const created = pg.rows("select * from create_player('u8-trainer', 'u8', 'Tiger', 0, 'yellow', 130, 30, 'lion', 'blue', 'boy')")[0]
    expect(created).toMatchObject({ group_id: 'u8', nickname: 'Tiger', jersey_number: 0, jersey_color: 'yellow', height_cm: 130, weight_kg: 30, mascot_id: 'lion', eye_color: 'blue', gender: 'boy' })
    const updated = pg.rows(`select * from update_player('u8-trainer', '${created.id}', 'u8', 'Fox', 9, 'red', 131, 31, 'shark', 'brown', 'girl')`)[0]
    expect(updated).toMatchObject({ id: created.id, nickname: 'Fox', jersey_number: 9, jersey_color: 'red', height_cm: 131, weight_kg: 31, mascot_id: 'shark', eye_color: 'brown', gender: 'girl' })
    pg.sql(`select delete_player('u8-trainer', '${created.id}')`)
    expect(pg.rows(`select * from players where id = '${created.id}'`)).toEqual([])
  })

  for (const code of ['wrong', 'ABC234', 'u10-trainer']) {
    it.each(['create', 'update', 'delete'])(`rejects %s with ${code} and leaves the roster unchanged`, (operation) => {
      const before = pg.rows('select * from players order by id')
      const calls: Record<string, string> = {
        create: `select create_player('${code}', 'u8', 'Intruder')`,
        update: `select update_player('${code}', '${child}', 'u10', 'Changed')`,
        delete: `select delete_player('${code}', '${child}')`,
      }
      expect(() => pg.sql(calls[operation])).toThrow(/invalid passcode/)
      expect(pg.rows('select * from players order by id')).toEqual(before)
    })
  }

  it.each([
    `select update_player('u8-trainer', '${missing}', 'u8', 'Missing')`,
    `select delete_player('u8-trainer', '${missing}')`,
  ])('rejects a nonexistent player: %s', (statement) => {
    expect(() => pg.sql(statement)).toThrow(/Player not found/)
  })

  it('deleting a player removes only that player and their ratings', () => {
    rate()
    rate('u8-trainer', u8Plan, 'dribbling', 3, sibling)
    pg.sql(`select delete_player('u8-trainer', '${child}')`)
    expect(pg.rows('select id from players')).toEqual([{ id: sibling }])
    expect(pg.rows('select player_id from player_progress_ratings')).toEqual([{ player_id: sibling }])
  })
})

describe('MUST SQL: promotion preserves identity and historical ratings', () => {
  it('U8 → U10 keeps individual history while each group keeps its own plan history', () => {
    const oldRating = rate()
    const moved = promote()
    expect(moved).toMatchObject({ id: child, group_id: 'u10', nickname: 'Lion', jersey_number: 7, jersey_color: 'blue', mascot_id: 'lion', eye_color: 'green', gender: 'girl', parent_code: 'ABC234' })
    const newRating = rate('u10-trainer', u10Plan, 'dribbling', 3)
    expect(pg.rows(`select * from player_progress_ratings where player_id = '${child}' order by created_at`)).toEqual([oldRating, newRating])

    // Same join/filter contract asserted against the Express endpoint in players.test.ts.
    const history = (group: string) => pg.rows(`
      select r.id, p.group_id as current_group, t.group_id as training_group
      from player_progress_ratings r
      join players p on p.id = r.player_id
      join plans t on t.id = r.plan_id
      where t.group_id = '${group}' order by r.created_at
    `)
    expect(history('u8')).toEqual([{ id: oldRating.id, current_group: 'u10', training_group: 'u8' }])
    expect(history('u10')).toEqual([{ id: newRating.id, current_group: 'u10', training_group: 'u10' }])
    expect(access('u8', 'ABC234')).toEqual([])
    expect(access('u10', 'ABC234')).toEqual([{ kind: 'parent', player_id: child, player_nickname: 'Lion' }])
  })

  it('requires the current group code, not the destination code, to promote', () => {
    const oldRating = rate()
    expect(() => promote('u10-trainer')).toThrow(/invalid passcode/)
    expect(pg.rows(`select group_id from players where id = '${child}'`)).toEqual([{ group_id: 'u8' }])
    expect(pg.rows('select * from player_progress_ratings')).toEqual([oldRating])
  })

  it('the old group code loses mutation access after promotion', () => {
    promote()
    expect(() => rate('u8-trainer', u10Plan)).toThrow(/invalid passcode/)
    expect(() => promote('u8-trainer', 'u8')).toThrow(/invalid passcode/)
    expect(() => pg.sql(`select delete_player('u8-trainer', '${child}')`)).toThrow(/invalid passcode/)
    expect(() => pg.sql(`select set_player_parent_code('u8-trainer', '${child}', null)`)).toThrow(/invalid passcode/)
    expect(rate('u10-trainer', u10Plan)).toMatchObject({ player_id: child, plan_id: u10Plan })
  })

  it('a nonexistent destination fails without changing the player or history', () => {
    const oldRating = rate()
    expect(() => promote('u8-trainer', 'missing')).toThrow(/foreign key constraint/)
    expect(pg.rows(`select group_id from players where id = '${child}'`)).toEqual([{ group_id: 'u8' }])
    expect(pg.rows('select * from player_progress_ratings')).toEqual([oldRating])
  })
})

describe('MUST SQL: rating upsert and plan/category validity', () => {
  it('re-rating upserts one row with the same identity and a refreshed timestamp', () => {
    const first = rate('u8-trainer', u8Plan, 'dribbling', 1)
    pg.sql(`update player_progress_ratings set created_at = '2000-01-01' where id = '${first.id}'`)
    const updated = rate('u8-trainer', u8Plan, 'dribbling', 3)
    expect(updated).toMatchObject({ id: first.id, player_id: child, plan_id: u8Plan, category_id: 'dribbling', rating: 3 })
    expect(new Date(updated.created_at).getTime()).toBeGreaterThan(new Date('2000-01-01').getTime())
    expect(pg.rows('select * from player_progress_ratings')).toEqual([updated])
  })

  it('keeps different players, plans and categories separate', () => {
    pg.sql(`insert into plans (id, group_id, training_date, title) values ('${missing}', 'u8', '2026-09-20', 'Next practice')`)
    const rows = [rate(), rate('u8-trainer', u8Plan, 'passing'), rate('u8-trainer', missing), rate('u8-trainer', u8Plan, 'dribbling', 2, sibling)]
    expect(new Set(rows.map((row) => row.id)).size).toBe(4)
    expect(pg.sql('select count(*) from player_progress_ratings')).toBe('4')
  })

  it.each(['wrong', 'ABC234', 'u10-trainer'])('rejects rating with %s without overwriting an existing rating', (code) => {
    const before = rate()
    expect(() => rate(code, u8Plan, 'dribbling', 3)).toThrow(/invalid passcode/)
    expect(pg.rows('select * from player_progress_ratings')).toEqual([before])
  })

  it.each([
    [missing, 'dribbling'], [u8Plan, 'missing-category'],
  ])('rejects nonexistent plan/category (%s, %s) with a useful error', (plan, category) => {
    expect(() => rate('u8-trainer', plan, category)).toThrow(
      plan === missing ? /Plan not found/ : /Category not found/,
    )
    expect(pg.rows('select * from player_progress_ratings')).toEqual([])
  })

  it.each([0, 4])('rejects an out-of-range database rating %i', (rating) => {
    expect(() => rate('u8-trainer', u8Plan, 'dribbling', rating)).toThrow(/check constraint/)
    expect(pg.rows('select * from player_progress_ratings')).toEqual([])
  })

  it('rejects a nonexistent player', () => {
    expect(() => rate('u8-trainer', u8Plan, 'dribbling', 2, missing)).toThrow(/Player not found/)
  })

  it('rejects a plan belonging to another group without contaminating that group history', () => {
    expect(() => rate('u8-trainer', u10Plan)).toThrow(/Plan does not belong to player group/)
    expect(pg.rows('select * from player_progress_ratings')).toEqual([])
  })

  it('rejects a category belonging to another sport', () => {
    pg.sql(`
      insert into sports (id, name, emoji) values ('football-test', 'Football test', '⚽');
      insert into skill_categories (id, sport_id, label, emoji)
      values ('football-test-category', 'football-test', 'Football skill', '⚽');
    `)
    expect(() => rate('u8-trainer', u8Plan, 'football-test-category')).toThrow(
      /Category does not belong to player sport/,
    )
    expect(pg.rows('select * from player_progress_ratings')).toEqual([])
  })

  it('accepts a category scoped to U8 and rejects it after promotion to U10', () => {
    pg.sql(`
      insert into skill_categories (id, sport_id, label, emoji)
      values ('u8-test-category', 'basketball', 'U8 skill', '🏀');
      insert into skill_category_groups (skill_category_id, group_template_id)
      values ('u8-test-category', 'u8');
    `)
    expect(rate('u8-trainer', u8Plan, 'u8-test-category')).toMatchObject({
      player_id: child,
      plan_id: u8Plan,
      category_id: 'u8-test-category',
    })
    promote()
    expect(() => rate('u10-trainer', u10Plan, 'u8-test-category')).toThrow(
      /Category is not available for player group/,
    )
    expect(pg.sql("select count(*) from player_progress_ratings where category_id = 'u8-test-category'"))
      .toBe('1')
  })
})

describe('MUST SQL: parent code lifecycle and read-only access', () => {
  it('issues, reads, rotates and revokes a parent code for exactly one player', () => {
    pg.sql(`select set_player_parent_code('u8-trainer', '${child}', 'NEW234')`)
    expect(pg.rows(`select parent_code from players where id = '${child}'`)).toEqual([{ parent_code: 'NEW234' }])
    expect(access('u8', 'ABC234')).toEqual([])
    expect(access('u8', 'NEW234')).toEqual([{ kind: 'parent', player_id: child, player_nickname: 'Lion' }])
    pg.sql(`select set_player_parent_code('u8-trainer', '${child}', 'NEXT23')`)
    expect(access('u8', 'NEW234')).toEqual([])
    expect(access('u8', 'NEXT23')).toHaveLength(1)
    pg.sql(`select set_player_parent_code('u8-trainer', '${child}', null)`)
    expect(pg.rows(`select parent_code from players where id = '${child}'`)).toEqual([{ parent_code: null }])
    expect(access('u8', 'NEXT23')).toEqual([])
    expect(access('u8', 'XYZ789')).toEqual([{ kind: 'parent', player_id: sibling, player_nickname: 'Shark' }])
  })

  it.each(['wrong', 'ABC234', 'u10-trainer'])('cannot issue or revoke with %s', (code) => {
    expect(() => pg.sql(`select set_player_parent_code('${code}', '${child}', 'NEW234')`)).toThrow(/invalid passcode/)
    expect(() => pg.sql(`select set_player_parent_code('${code}', '${child}', null)`)).toThrow(/invalid passcode/)
    expect(access('u8', 'ABC234')).toHaveLength(1)
  })

  it('cannot assign another child the same parent code', () => {
    expect(() => pg.sql(`select set_player_parent_code('u8-trainer', '${sibling}', 'ABC234')`)).toThrow(/unique constraint/)
    expect(access('u8', 'XYZ789')).toHaveLength(1)
  })

  it('cannot issue a code for a nonexistent player', () => {
    expect(() => pg.sql(`select set_player_parent_code('u8-trainer', '${missing}', 'NEW234')`)).toThrow(/Player not found/)
  })
})

describe('MUST SQL: plan CRUD, date uniqueness and group scoping', () => {
  it('creates, edits and deletes a plan without modifying another group', () => {
    const created = pg.rows("select * from create_plan('u8-trainer', 'u8', '2026-09-20', 'Practice', '🏀', array['dribble'])")[0]
    expect(created).toMatchObject({ group_id: 'u8', training_date: '2026-09-20', exercise_ids: ['dribble'] })
    const updated = pg.rows(`select * from update_plan('u8-trainer', '${created.id}', '2026-09-21', 'Changed', '🎯', array['pass'])`)[0]
    expect(updated).toMatchObject({ id: created.id, group_id: 'u8', title: 'Changed', training_date: '2026-09-21', exercise_ids: ['pass'] })
    pg.sql(`select delete_plan('u8-trainer', '${created.id}')`)
    expect(pg.rows(`select * from plans where id = '${created.id}'`)).toEqual([])
    expect(pg.sql('select count(*) from plans')).toBe('2')
  })

  it('allows the same date across groups but rejects duplicate dates within one group', () => {
    expect(pg.sql("select count(*) from plans where training_date = '2026-09-19'")).toBe('2')
    expect(() => pg.sql("insert into plans (group_id, training_date, title) values ('u8', '2026-09-19', 'Duplicate')")).toThrow(/plans_group_date_unique_idx/)
    pg.sql("insert into plans (group_id, training_date, title) values ('u8', '2026-09-20', 'Next')")
    expect(() => pg.sql("update plans set training_date = '2026-09-19' where training_date = '2026-09-20'")).toThrow(/plans_group_date_unique_idx/)
  })

  it.each(['wrong', 'ABC234', 'u10-trainer'])('rejects every plan mutation with %s', (code) => {
    const before = pg.rows('select * from plans order by id')
    expect(() => pg.sql(`select create_plan('${code}', 'u8', '2026-09-20', 'Bad', '🏀', '{}'::text[])`)).toThrow(/invalid passcode/)
    expect(() => pg.sql(`select update_plan('${code}', '${u8Plan}', '2026-09-20', 'Bad', '🏀', '{}'::text[])`)).toThrow(/invalid passcode/)
    expect(() => pg.sql(`select delete_plan('${code}', '${u8Plan}')`)).toThrow(/invalid passcode/)
    expect(pg.rows('select * from plans order by id')).toEqual(before)
  })
})
