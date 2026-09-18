-- Source of truth for the Supabase schema — run this once in the Supabase project's SQL
-- editor (Project -> SQL Editor -> New query). Owned here, not in the frontend repo, since
-- this API is the only thing that talks to Supabase (see README.md).
--
-- Shared, dated training plans for U8 Basketball Training, writable by any trainer who knows
-- their group's passcode. Reads are public; writes go through passcode-checked RPC functions
-- only (the passcode itself is never exposed to the browser) — this API fronts those, see
-- src/routes/*.ts.
--
-- GDPR note (see basketball/PRIVACY.md in the frontend repo): this schema intentionally
-- stores NO data identifying a real child — the `players` table (below) holds only a
-- self-chosen nickname, never a real name, and there is deliberately no link from a player
-- row to any parent/guardian identity. Trainer/admin identity (email) does start appearing
-- with the multi-tenancy tables below, which is real personal data for the *adults* running
-- the club — keep that in mind if this ever needs a real privacy review. When creating the
-- Supabase project, pick an EU region (e.g. Frankfurt / eu-central-1) to keep data residency
-- in the EU/EEA.

create extension if not exists pgcrypto;

-- Sports this app can run training plans for. Basketball is the first — a club's sport_id
-- is what makes categories/exercises (still basketball-only client-side, see
-- src/data/categories.ts and src/data/exercises.ts) apply to the right club.
create table if not exists sports (
  id text primary key,
  name text not null,
  emoji text not null
);

insert into sports (id, name, emoji)
values ('basketball', 'Basketball', '🏀')
on conflict (id) do nothing;

alter table sports enable row level security;

drop policy if exists "sports are publicly readable" on sports;
create policy "sports are publicly readable" on sports
  for select using (true);

grant select on sports to anon;
revoke insert, update, delete on sports from anon;

-- Mascots (sports-training-api#43) — a player's avatar animal. Deliberately NOT sport-scoped:
-- the roster and each animal's identity (id/name) are global, so a kid who picked "lion" keeps
-- being the same lion if their club later adds a second sport — only the artwork changes (see
-- `mascot_avatars` below). Starting with just lion; more animals land as art is ready.
create table if not exists mascots (
  id text primary key,
  name text not null,
  sort_order int not null default 0
);

insert into mascots (id, name, sort_order) values
  ('lion', 'Lion', 1)
on conflict (id) do nothing;

alter table mascots enable row level security;

drop policy if exists "mascots are publicly readable" on mascots;
create policy "mascots are publicly readable" on mascots
  for select using (true);

grant select on mascots to anon;
revoke insert, update, delete on mascots from anon;

-- Sport-scoped, life-stage-scoped artwork for a mascot. This is where a lion's basketball
-- jersey differs from its (future) other-sport look, and where baby/child/teen/adult art
-- lives — the mascot's identity (`mascot_id`) stays constant, only the image changes.
-- image_url starts empty (no art yet, see #43) — rows get added once assets exist.
create table if not exists mascot_avatars (
  id uuid primary key default gen_random_uuid(),
  mascot_id text not null references mascots(id),
  sport_id text not null references sports(id),
  stage text not null check (stage in ('baby', 'child', 'teen', 'adult')),
  image_url text not null,
  unique (mascot_id, sport_id, stage)
);

alter table mascot_avatars enable row level security;

drop policy if exists "mascot avatars are publicly readable" on mascot_avatars;
create policy "mascot avatars are publicly readable" on mascot_avatars
  for select using (true);

grant select on mascot_avatars to anon;
revoke insert, update, delete on mascot_avatars from anon;

-- Clubs this app serves. Today there's exactly one (Dunckers Hilversum) and the app just
-- reads the first row, but modeling it as a table now means multi-club support later is a
-- matter of resolving the active club (e.g. by slug/subdomain) rather than a schema change.
create table if not exists clubs (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  logo_url text,
  created_at timestamptz not null default now()
);

insert into clubs (slug, name, logo_url)
values ('dunckers-hilversum', 'Dunckers Hilversum', 'logos/deDunkers.png')
on conflict (slug) do nothing;

alter table clubs enable row level security;

drop policy if exists "clubs are publicly readable" on clubs;
create policy "clubs are publicly readable" on clubs
  for select using (true);

grant select on clubs to anon;
revoke insert, update, delete on clubs from anon;

-- ============================================================================================
-- Multi-tenancy + groups (see sports-training-api#9 — "individual players as a team").
-- Shape: admins buy sport_subscriptions; a club belongs to one sport_subscription; a club's
-- groups are admin-renameable instances of a group_templates catalog entry (the catalog is
-- what actually determines training content/age-band — an admin can rename their group to
-- anything, the template is what keeps "U8 content" attached to it).
--
-- Auth doesn't exist yet (see README), so admins/sport_subscriptions aren't exposed to anon
-- at all today — only service_role (this API) touches them.
-- ============================================================================================

-- The tenant who bought the tool. No login yet — just an identity to hang sport_subscriptions
-- off of. CHANGE the seeded email below to your own before relying on it for anything.
create table if not exists admins (
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  name text,
  created_at timestamptz not null default now()
);

insert into admins (email, name)
values ('admin@example.com', 'Dunckers Hilversum admin')
on conflict (email) do nothing;

alter table admins enable row level security;
-- No policies at all: not readable by anon (no admin UI/auth yet), only service_role.

-- Which sports an admin has purchased access to.
create table if not exists sport_subscriptions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references admins(id) on delete cascade,
  sport_id text not null references sports(id),
  created_at timestamptz not null default now(),
  unique (admin_id, sport_id)
);

alter table sport_subscriptions enable row level security;
-- No policies: same as admins, service_role only for now.

insert into sport_subscriptions (admin_id, sport_id)
select id, 'basketball' from admins where email = 'admin@example.com'
on conflict (admin_id, sport_id) do nothing;

-- Backfill: the existing club belongs to that subscription.
alter table clubs add column if not exists sport_subscription_id uuid references sport_subscriptions(id);

update clubs
set sport_subscription_id = ss.id
from sport_subscriptions ss
join admins a on a.id = ss.admin_id
where clubs.slug = 'dunckers-hilversum'
  and a.email = 'admin@example.com'
  and ss.sport_id = 'basketball'
  and clubs.sport_subscription_id is null;

-- Group templates: the catalog of age/skill bands this app has training content for.
-- 'coming_soon' entries can show in a UI group-selector as disabled/upcoming.
-- mascot_stage is which life-stage mascot avatar (see `mascot_avatars` below) a group's
-- players are shown by default — U8 kids get the baby/child-stage art, older groups get
-- teen/adult, so the animal visibly "grows up" alongside the age band, not the individual
-- player (there's no player birthdate to derive this from).
create table if not exists group_templates (
  id text primary key,
  sport_id text not null references sports(id),
  label text not null,
  emoji text not null default '🏀',
  status text not null default 'available' check (status in ('available', 'coming_soon')),
  sort_order int not null default 0,
  mascot_stage text not null default 'child'
    check (mascot_stage in ('baby', 'child', 'teen', 'puber', 'mid-teens', 'adolescence', 'grownup'))
);

alter table group_templates add column if not exists mascot_stage text not null default 'child';

-- Widened from ('baby','child','teen','adult') to the full 7-stage breakdown mascot_stages now
-- uses -- drop+recreate instead of the old if-not-exists guard, since that guard never touches
-- an already-existing constraint.
alter table group_templates drop constraint if exists group_templates_mascot_stage_check;
alter table group_templates add constraint group_templates_mascot_stage_check
  check (mascot_stage in ('baby', 'child', 'teen', 'puber', 'mid-teens', 'adolescence', 'grownup'));

insert into group_templates (id, sport_id, label, emoji, status, sort_order, mascot_stage) values
  ('u8', 'basketball', 'U8', '🏀', 'available', 1, 'baby'),
  ('u10', 'basketball', 'U10', '🏀', 'available', 2, 'child'),
  ('u12', 'basketball', 'U12', '🏀', 'coming_soon', 3, 'teen'),
  ('u14', 'basketball', 'U14', '🏀', 'coming_soon', 4, 'puber'),
  ('u16', 'basketball', 'U16', '🏀', 'coming_soon', 5, 'mid-teens'),
  ('u18', 'basketball', 'U18', '🏀', 'coming_soon', 6, 'adolescence'),
  ('grownup', 'basketball', '18+', '🏀', 'coming_soon', 7, 'grownup')
on conflict (id) do update set mascot_stage = excluded.mascot_stage;

alter table group_templates enable row level security;

drop policy if exists "group templates are publicly readable" on group_templates;
create policy "group templates are publicly readable" on group_templates
  for select using (true);

grant select on group_templates to anon;
revoke insert, update, delete on group_templates from anon;

-- Groups: a club's actual, admin-renameable instances of a template — and, since each group
-- has its OWN trainer passcode (a code valid for U8 does not unlock U10), this is also what
-- verify_passcode() below checks against. `passcode` is never granted to anon (see the
-- column-level grant after the table), same principle as the old app_config.team_passcode.
create table if not exists groups (
  id text primary key,
  club_id uuid not null references clubs(id) on delete cascade,
  template_id text not null references group_templates(id),
  name text not null,
  passcode text not null default 'changeme',
  created_at timestamptz not null default now()
);

-- Seed 'u8' and 'u10' (u10's template is 'available'). Both default to 'changeme' — set u8's
-- to your actual existing trainer code so already-remembered devices keep working, e.g.:
--   update groups set passcode = 'your-real-u8-code' where id = 'u8';
insert into groups (id, club_id, template_id, name, passcode)
select 'u8', c.id, 'u8', 'U8', 'changeme'
from clubs c
where c.slug = 'dunckers-hilversum'
on conflict (id) do nothing;

insert into groups (id, club_id, template_id, name, passcode)
select 'u10', c.id, 'u10', 'U10', 'changeme'
from clubs c
where c.slug = 'dunckers-hilversum'
on conflict (id) do nothing;

alter table groups enable row level security;

drop policy if exists "groups are publicly readable" on groups;
create policy "groups are publicly readable" on groups
  for select using (true);

-- Column-level grant, deliberately excluding `passcode` — same "never readable directly"
-- principle as the old app_config.team_passcode, just scoped per row instead of one global row.
grant select (id, club_id, template_id, name, created_at) on groups to anon;
revoke insert, update, delete on groups from anon;

-- Checks a passcode against a specific group's stored value without ever returning it.
create or replace function verify_passcode(p_group_id text, input text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from groups where id = p_group_id and passcode = input
  );
$$;

grant execute on function verify_passcode(text, text) to anon;

create table if not exists plans (
  id uuid primary key default gen_random_uuid(),
  group_id text not null references groups(id),
  training_date date not null,
  title text not null,
  emoji text not null default '🏀',
  exercise_ids text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One training per date per group — enforced here too so two trainers racing to plan
-- the same date can't both succeed, not just caught client-side.
create unique index if not exists plans_group_date_unique_idx on plans (group_id, training_date);

-- Legacy: the single shared passcode this app used before groups each had their own (see
-- `groups.passcode` above, which verify_passcode() now checks instead). Kept, unused, rather
-- than deleted outright — nothing reads this anymore.
create table if not exists app_config (
  key text primary key,
  value text not null
);

insert into app_config (key, value)
values ('team_passcode', 'changeme')
on conflict (key) do nothing;

alter table plans enable row level security;
alter table app_config enable row level security;

-- Anyone can read the list of planned trainings.
drop policy if exists "plans are publicly readable" on plans;
create policy "plans are publicly readable" on plans
  for select using (true);

-- No select policy on app_config at all — legacy table, nothing should read it anymore.

create or replace function create_plan(
  passcode text,
  p_group_id text,
  p_training_date date,
  p_title text,
  p_emoji text,
  p_exercise_ids text[]
)
returns plans
language plpgsql
security definer
set search_path = public
as $$
declare
  result plans;
begin
  if not verify_passcode(p_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  insert into plans (group_id, training_date, title, emoji, exercise_ids)
  values (p_group_id, p_training_date, p_title, p_emoji, p_exercise_ids)
  returning * into result;
  return result;
exception
  when unique_violation then
    raise exception 'This group already has a training planned on that date';
end;
$$;

create or replace function update_plan(
  passcode text,
  p_id uuid,
  p_training_date date,
  p_title text,
  p_emoji text,
  p_exercise_ids text[]
)
returns plans
language plpgsql
security definer
set search_path = public
as $$
declare
  result plans;
  v_group_id text;
begin
  select group_id into v_group_id from plans where id = p_id;
  if v_group_id is null then
    raise exception 'Plan not found';
  end if;
  if not verify_passcode(v_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  update plans
  set training_date = p_training_date,
      title = p_title,
      emoji = p_emoji,
      exercise_ids = p_exercise_ids,
      updated_at = now()
  where id = p_id
  returning * into result;
  return result;
exception
  when unique_violation then
    raise exception 'This group already has a training planned on that date';
end;
$$;

create or replace function delete_plan(passcode text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id text;
begin
  select group_id into v_group_id from plans where id = p_id;
  if v_group_id is null then
    raise exception 'Plan not found';
  end if;
  if not verify_passcode(v_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  delete from plans where id = p_id;
end;
$$;

-- The anon (public) role may only read plans directly, and mutate only via the
-- passcode-checked RPCs above — it has no direct insert/update/delete grant.
grant select on plans to anon;
revoke insert, update, delete on plans from anon;
grant execute on function create_plan(text, text, date, text, text, text[]) to anon;
grant execute on function update_plan(text, uuid, date, text, text, text[]) to anon;
grant execute on function delete_plan(text, uuid) to anon;

-- One row per group: the shared, live session clock every trainer's device polls and controls,
-- so starting/pausing/skipping on one phone shows up on everyone else's within a couple of
-- seconds. `elapsed_seconds` is the accumulated time as of the last start/pause/seek;
-- `running_since` is only set while status = 'running', and the API adds (now - running_since)
-- on top of `elapsed_seconds` when reporting the live value — see src/routes/sessions.ts.
create table if not exists live_sessions (
  group_id text primary key references groups(id),
  status text not null default 'idle' check (status in ('idle', 'running', 'paused')),
  elapsed_seconds integer not null default 0,
  running_since timestamptz,
  updated_at timestamptz not null default now()
);

alter table live_sessions enable row level security;

-- Anyone can read the live clock (so unlocked and locked devices alike stay in sync); only the
-- API (via service_role, passcode-gated the same way as plans) ever writes to it.
drop policy if exists "live sessions are publicly readable" on live_sessions;
create policy "live sessions are publicly readable" on live_sessions
  for select using (true);

grant select on live_sessions to anon;
revoke insert, update, delete on live_sessions from anon;

-- ============================================================================================
-- Players + progress tracking (see sports-training-api#9). Players are a persistent identity:
-- `group_id` is their CURRENT group, so reassigning it (e.g. promoted U8 -> U10 next season)
-- keeps the same player row — nickname and full progress history in player_progress_ratings
-- stay intact across the move.
-- ============================================================================================

-- jersey_color is a fixed small palette (not free-form hex) so player cards stay visually
-- consistent — see sports-training-ui#22. jersey_number has no uniqueness constraint: real
-- teams do end up with number collisions within a group, and that's fine here too.
create table if not exists players (
  id uuid primary key default gen_random_uuid(),
  group_id text not null references groups(id),
  nickname text not null,
  jersey_number int,
  jersey_color text check (jersey_color in ('orange', 'blue', 'red', 'green', 'purple', 'black', 'white', 'yellow')),
  -- Optional bio details a trainer can fill in — nullable since most groups won't bother, and
  -- U8/U10 kids grow fast enough that a stale value is worse than none. Centimeters/kilograms
  -- (metric) since Duncker's Hilversum, the first club on this app, is Dutch.
  height_cm int check (height_cm is null or height_cm between 50 and 250),
  weight_kg int check (weight_kg is null or weight_kg between 10 and 200),
  -- The animal a player picked as their avatar (see `mascots`/`mascot_avatars` below). Nullable
  -- — picking one is optional. Not FK'd to a specific sport: the same mascot_id follows the
  -- player if their club adds a second sport later, only the artwork changes.
  mascot_id text references mascots(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Backfill for existing installs where `players` was created before these columns existed.
alter table players add column if not exists jersey_number int;
alter table players add column if not exists jersey_color text;
alter table players add column if not exists height_cm int;
alter table players add column if not exists weight_kg int;
alter table players add column if not exists mascot_id text references mascots(id);
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'players_height_cm_check'
  ) then
    alter table players add constraint players_height_cm_check
      check (height_cm is null or height_cm between 50 and 250);
  end if;
  if not exists (
    select 1 from pg_constraint where conname = 'players_weight_kg_check'
  ) then
    alter table players add constraint players_weight_kg_check
      check (weight_kg is null or weight_kg between 10 and 200);
  end if;
end $$;
do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'players_jersey_color_check'
  ) then
    alter table players add constraint players_jersey_color_check
      check (jersey_color in ('orange', 'blue', 'red', 'green', 'purple', 'black', 'white', 'yellow'));
  end if;
end $$;

create index if not exists players_group_id_idx on players (group_id);

alter table players enable row level security;

drop policy if exists "players are publicly readable" on players;
create policy "players are publicly readable" on players
  for select using (true);

grant select on players to anon;
revoke insert, update, delete on players from anon;

-- Dropped and recreated with new params rather than a plain `create or replace`: a different
-- parameter count creates a separate overload instead of replacing the function, which would
-- leave both the old 3-arg and new 5-arg versions in the database and make calls ambiguous.
drop function if exists create_player(text, text, text);
drop function if exists create_player(text, text, text, int, text);
drop function if exists create_player(text, text, text, int, text, int, int);

create or replace function create_player(
  passcode text,
  p_group_id text,
  p_nickname text,
  p_jersey_number int default null,
  p_jersey_color text default null,
  p_height_cm int default null,
  p_weight_kg int default null,
  p_mascot_id text default null
)
returns players
language plpgsql
security definer
set search_path = public
as $$
declare
  result players;
begin
  if not verify_passcode(p_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  insert into players (group_id, nickname, jersey_number, jersey_color, height_cm, weight_kg, mascot_id)
  values (p_group_id, p_nickname, p_jersey_number, p_jersey_color, p_height_cm, p_weight_kg, p_mascot_id)
  returning * into result;
  return result;
end;
$$;

-- Reassigning to a new group only requires the passcode for the player's CURRENT group —
-- moving a promoted player into U10 doesn't require already knowing U10's code.
drop function if exists update_player(text, uuid, text, text);
drop function if exists update_player(text, uuid, text, text, int, text);
drop function if exists update_player(text, uuid, text, text, int, text, int, int);

create or replace function update_player(
  passcode text,
  p_id uuid,
  p_group_id text,
  p_nickname text,
  p_jersey_number int default null,
  p_jersey_color text default null,
  p_height_cm int default null,
  p_weight_kg int default null,
  p_mascot_id text default null
)
returns players
language plpgsql
security definer
set search_path = public
as $$
declare
  result players;
  v_current_group_id text;
begin
  select group_id into v_current_group_id from players where id = p_id;
  if v_current_group_id is null then
    raise exception 'Player not found';
  end if;
  if not verify_passcode(v_current_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  update players
  set group_id = p_group_id,
      nickname = p_nickname,
      jersey_number = p_jersey_number,
      jersey_color = p_jersey_color,
      height_cm = p_height_cm,
      weight_kg = p_weight_kg,
      mascot_id = p_mascot_id,
      updated_at = now()
  where id = p_id
  returning * into result;
  return result;
end;
$$;

create or replace function delete_player(passcode text, p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_group_id text;
begin
  select group_id into v_group_id from players where id = p_id;
  if v_group_id is null then
    raise exception 'Player not found';
  end if;
  if not verify_passcode(v_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  delete from players where id = p_id;
end;
$$;

grant execute on function create_player(text, text, text, int, text, int, int, text) to anon;
grant execute on function update_player(text, uuid, text, text, int, text, int, int, text) to anon;
grant execute on function delete_player(text, uuid) to anon;

-- Skill categories a player's progress can be rated on — same taxonomy as training categories
-- (src/data/categories.ts in the UI repo) minus 'warmup', so progress ratings and training
-- content share one vocabulary. 'agility' doubles as the stamina/conditioning bucket.
create table if not exists skill_categories (
  id text primary key,
  sport_id text not null references sports(id),
  label text not null,
  emoji text not null,
  sort_order int not null default 0,
  -- Nullable self-reference: a top-level category (e.g. 'dribbling') has parent_id null; a
  -- finer sub-skill (e.g. 'dribbling_left') points back at it so the UI can group "Left-hand
  -- dribbling" / "Right-hand dribbling" under a "Dribbling" heading instead of a flat list.
  -- Existing ratings on the six original ids are unaffected — this is purely additive.
  parent_id text references skill_categories(id)
);

-- Backfill for existing installs where `skill_categories` was created before this column
-- existed.
alter table skill_categories add column if not exists parent_id text references skill_categories(id);

insert into skill_categories (id, sport_id, label, emoji, sort_order, parent_id) values
  ('dribbling', 'basketball', 'Dribbling', '⛹️', 1, null),
  ('passing', 'basketball', 'Passing', '🤝', 2, null),
  ('shooting', 'basketball', 'Shooting', '🎯', 3, null),
  ('defense', 'basketball', 'Defense & Movement', '🛡️', 4, null),
  ('agility', 'basketball', 'Agility & Stamina', '🏃', 5, null),
  ('teamplay', 'basketball', 'Team Play & Game', '🏆', 6, null)
on conflict (id) do nothing;

-- Finer sub-skills — common youth-basketball scouting breakdowns (strong/weak hand, pass
-- types, shot forms, defensive stance) — added under the six existing categories so a trainer
-- can rate at whichever granularity fits the moment; the parent category itself stays ratable
-- too, for a quick overall tap.
insert into skill_categories (id, sport_id, label, emoji, sort_order, parent_id) values
  ('dribbling_strong_hand', 'basketball', 'Strong-hand dribbling', '✋', 11, 'dribbling'),
  ('dribbling_weak_hand', 'basketball', 'Weak-hand dribbling', '🤚', 12, 'dribbling'),
  ('dribbling_change_of_direction', 'basketball', 'Change of direction', '↔️', 13, 'dribbling'),
  ('passing_chest', 'basketball', 'Chest pass', '📤', 21, 'passing'),
  ('passing_bounce', 'basketball', 'Bounce pass', '⤵️', 22, 'passing'),
  ('shooting_form', 'basketball', 'Shooting form', '📐', 31, 'shooting'),
  ('shooting_layup', 'basketball', 'Layups', '🏀', 32, 'shooting'),
  ('defense_stance', 'basketball', 'Defensive stance & footwork', '🦶', 41, 'defense'),
  ('defense_on_ball', 'basketball', 'On-ball defense', '🙋', 42, 'defense')
on conflict (id) do nothing;

-- Top-level, not a skill drill: how much the player enjoyed the session. Rated through the
-- same rate_player flow as everything else so no new rating infra is needed.
insert into skill_categories (id, sport_id, label, emoji, sort_order, parent_id) values
  ('enjoyment', 'basketball', 'Enjoyment', '😄', 7, null)
on conflict (id) do nothing;

alter table skill_categories enable row level security;

drop policy if exists "skill categories are publicly readable" on skill_categories;
create policy "skill categories are publicly readable" on skill_categories
  for select using (true);

grant select on skill_categories to anon;
revoke insert, update, delete on skill_categories from anon;

-- Optionally scopes a skill category to specific group templates (age bands) — e.g. a
-- sub-skill that only makes sense for U8. A category with NO rows here applies to every
-- group, so all existing categories keep showing everywhere they always have; only new
-- categories that need scoping get explicit rows added.
create table if not exists skill_category_groups (
  skill_category_id text not null references skill_categories(id) on delete cascade,
  group_template_id text not null references group_templates(id) on delete cascade,
  primary key (skill_category_id, group_template_id)
);

alter table skill_category_groups enable row level security;

drop policy if exists "skill category groups are publicly readable" on skill_category_groups;
create policy "skill category groups are publicly readable" on skill_category_groups
  for select using (true);

grant select on skill_category_groups to anon;
revoke insert, update, delete on skill_category_groups from anon;

-- One rating per player per category per training — mirrors the existing "Kids liked it?"
-- reaction widget (😐/🙂/🤩) already in the Session screen, just per-player instead of
-- per-exercise. `rating` is 1-3 (😐=1, 🙂=2, 🤩=3) to keep logging as fast as that tap.
create table if not exists player_progress_ratings (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  plan_id uuid not null references plans(id) on delete cascade,
  category_id text not null references skill_categories(id),
  rating smallint not null check (rating between 1 and 3),
  created_at timestamptz not null default now(),
  unique (player_id, plan_id, category_id)
);

create index if not exists player_progress_ratings_player_idx on player_progress_ratings (player_id);

alter table player_progress_ratings enable row level security;

drop policy if exists "progress ratings are publicly readable" on player_progress_ratings;
create policy "progress ratings are publicly readable" on player_progress_ratings
  for select using (true);

grant select on player_progress_ratings to anon;
revoke insert, update, delete on player_progress_ratings from anon;

-- Resolves the group via the player (not a separate p_group_id param) so a rating can only
-- ever be filed by someone who holds that player's CURRENT group's passcode.
create or replace function rate_player(
  passcode text,
  p_player_id uuid,
  p_plan_id uuid,
  p_category_id text,
  p_rating smallint
)
returns player_progress_ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  result player_progress_ratings;
  v_group_id text;
begin
  select group_id into v_group_id from players where id = p_player_id;
  if v_group_id is null then
    raise exception 'Player not found';
  end if;
  if not verify_passcode(v_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  insert into player_progress_ratings (player_id, plan_id, category_id, rating)
  values (p_player_id, p_plan_id, p_category_id, p_rating)
  on conflict (player_id, plan_id, category_id)
  do update set rating = excluded.rating, created_at = now()
  returning * into result;
  return result;
end;
$$;

grant execute on function rate_player(text, uuid, uuid, text, smallint) to anon;

-- ============================================================================================
-- Exercise library (sports-training-api#24) — training content used to live only as hardcoded
-- TypeScript in the sports-training-ui repo (src/data/exercises.ts / categories.ts). Moving it
-- here means a new sport, or a new exercise for the existing one, is a data change (a row),
-- not a code change/deploy. Public read, no passcode — this is reference content, not a
-- club's own data, same treatment as `sports`/`group_templates`.
-- ============================================================================================

-- Exercise categories (what an exercise trains). Deliberately its own table, not a reuse of
-- `skill_categories` above: skill_categories is the *rateable* taxonomy (excludes 'warmup' on
-- purpose, since nobody rates a player's warm-up), this is the *training-content* taxonomy
-- (includes 'warmup'). The two overlap but serve different features.
create table if not exists exercise_categories (
  id text primary key,
  sport_id text not null references sports(id),
  label text not null,
  emoji text not null,
  sort_order int not null default 0
);

insert into exercise_categories (id, sport_id, label, emoji, sort_order) values
  ('warmup', 'basketball', 'Warm-up & Fun', '🔥', 0),
  ('dribbling', 'basketball', 'Dribbling', '⛹️', 1),
  ('passing', 'basketball', 'Passing', '🤝', 2),
  ('shooting', 'basketball', 'Shooting', '🎯', 3),
  ('defense', 'basketball', 'Defense & Movement', '🛡️', 4),
  ('agility', 'basketball', 'Agility & Coordination', '🏃', 5),
  ('teamplay', 'basketball', 'Team Play & Game', '🏆', 6)
on conflict (id) do nothing;

alter table exercise_categories enable row level security;

drop policy if exists "exercise categories are publicly readable" on exercise_categories;
create policy "exercise categories are publicly readable" on exercise_categories
  for select using (true);

grant select on exercise_categories to anon;
revoke insert, update, delete on exercise_categories from anon;

-- The exercise library itself. `categories` and `groups` are plain text[] with no FK — same
-- pragmatic style as `plans.exercise_ids` above, since Postgres has no native array-FK and a
-- join table would be overkill for a handful of tags per row.
create table if not exists exercises (
  id text primary key,
  sport_id text not null references sports(id),
  title text not null,
  emoji text not null,
  subtitle text,
  duration_minutes int not null,
  goal text not null,
  steps text[] not null default '{}',
  -- Bilingual coach cues, e.g. [{"nl": "Laag!", "en": "Low!"}] — nullable, not every exercise has them.
  cues jsonb,
  -- A break isn't a "graded" exercise — hidden from rating/library filtering by default (mirrors
  -- the old Exercise.isBreak flag).
  is_break boolean not null default false,
  -- Category ids this exercise trains (see exercise_categories above).
  categories text[] not null default '{}',
  -- Group-template ids (see group_templates) this exercise is appropriate for. Null/empty =
  -- applies to every group — most exercises are shared fundamentals; only set this when an
  -- exercise's framing (age-appropriate content, difficulty) is group-specific.
  groups text[],
  sort_order int not null default 0
);

alter table exercises enable row level security;

drop policy if exists "exercises are publicly readable" on exercises;
create policy "exercises are publicly readable" on exercises
  for select using (true);

grant select on exercises to anon;
revoke insert, update, delete on exercises from anon;

-- Seed: the basketball library that used to live in sports-training-ui's src/data/exercises.ts.
insert into exercises (id, sport_id, title, emoji, subtitle, duration_minutes, goal, steps, cues, is_break, categories, groups, sort_order) values
  ($x$welcome$x$, 'basketball', $x$Welcome circle$x$, $x$👋$x$, null, 5, $x$Learn names, set the tone, agree on rules.$x$, ARRAY[$x$Children place one foot on a ball, or hold it still.$x$, $x$Say: "Welkom! Vandaag gaan we spelen, dribbelen, passen en schieten." / "Welcome! Today we’ll play, dribble, pass and shoot."$x$, $x$Introduce both coaches.$x$, $x$Each child says their name and their favourite animal.$x$, $x$Explain three team rules: Stop signal (hand up, "Freeze! / Stop!"), Be kind ("We helpen elkaar."), Have fun (mistakes are allowed).$x$, $x$Quick parent message: "Vandaag draait vooral om plezier, veiligheid en iedereen veel met de bal laten spelen. Aan het einde mogen jullie luid aanmoedigen!"$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Welkom!$x$, 'en', $x$Welcome!$x$), jsonb_build_object('nl', $x$Stop / bevries$x$, 'en', $x$Stop / freeze$x$), jsonb_build_object('nl', $x$We helpen elkaar$x$, 'en', $x$We help each other$x$)), false, ARRAY[$x$warmup$x$]::text[], ARRAY[$x$u8$x$]::text[], 1),
  ($x$wall-of-china$x$, 'basketball', $x$Wall of china$x$, $x$🧱$x$, null, 5, $x$Warm up, run around, have fun as a group.$x$, ARRAY[$x$Pick one child to be the "tagger" who tries to tag other players.$x$, $x$When the tagger tags someone, they join hands and try to tag other players together.$x$, $x$The wall gets longer and longer as more children are tagged.$x$, $x$When the wall reaches 4 kids long, it splits into two separate walls.$x$, $x$Keep playing until one kid is left untagged.$x$]::text[], null, false, ARRAY[$x$warmup$x$, $x$agility$x$]::text[], ARRAY[$x$u8$x$]::text[], 2),
  ($x$mario-jump-crab-cheetah$x$, 'basketball', $x$Mario, Jump, Crab, Cheetah$x$, $x$🦘$x$, $x$Corner-to-corner movement circuit$x$, 5, $x$Coordination, fun movement patterns, listening for the whistle.$x$, ARRAY[$x$Start at corner 1.$x$, $x$Corner 1 → middle line: run while jumping and punching the sky, like Mario.$x$, $x$Middle line → corner 2: two quick running steps, then explode up into one big jump — like a rocket launch!$x$, $x$Corner 2 → corner 3: crab run (low squat).$x$, $x$Corner 3 → corner 4: run as fast as you can, like a cheetah.$x$, $x$Round 1: do the full circuit normally.$x$, $x$Round 2: same circuit, but freeze completely when the whistle blows.$x$]::text[], null, false, ARRAY[$x$agility$x$, $x$warmup$x$]::text[], ARRAY[$x$u8$x$]::text[], 3),
  ($x$everybody-dribbles$x$, 'basketball', $x$Everybody dribbles$x$, $x$⛹️$x$, null, 5, $x$Ball familiarity and dribbling control.$x$, ARRAY[$x$Give every child a ball and define a safe playing area.$x$, $x$Round 1 – Ball gevoel (ball feel): move the ball around the body without bouncing — left to right, around the tummy, throw and catch.$x$, $x$Round 2 – Body challenges: call out Low/laag, High/hoog, Other hand/andere hand, Sit down and stand up, Turn around/draai rond.$x$, $x$Round 3 – Traffic lights: dribble corner to corner around the court. Green/groen = dribble forwards, Orange/oranje = dribble backwards, Red/rood = stop the ball and freeze.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Laag$x$, 'en', $x$Low$x$), jsonb_build_object('nl', $x$Hoog$x$, 'en', $x$High$x$), jsonb_build_object('nl', $x$Andere hand$x$, 'en', $x$Other hand$x$), jsonb_build_object('nl', $x$Groen$x$, 'en', $x$Green — forwards$x$), jsonb_build_object('nl', $x$Oranje$x$, 'en', $x$Orange — backwards$x$), jsonb_build_object('nl', $x$Rood$x$, 'en', $x$Red — stop & freeze$x$)), false, ARRAY[$x$dribbling$x$, $x$agility$x$]::text[], null, 4),
  ($x$pogo-bounces$x$, 'basketball', $x$Pogo bounces$x$, $x$🐇$x$, $x$Pogo jumps drill$x$, 4, $x$Light, springy feet and ankle bounce.$x$, ARRAY[$x$Stand tall, feet together, arms relaxed — pretend you have a pogo stick under your feet.$x$, $x$Bounce up and down fast using only your ankles, not big knee bends.$x$, $x$Land soft and quiet on your toes every time, like a bunny.$x$, $x$Bounce for 10 seconds, rest 10 seconds. Repeat 3-4 rounds.$x$, $x$Challenge round: bounce while clapping above your head, or bounce slowly turning in a circle.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Licht! Licht!$x$, 'en', $x$Light! Light!$x$), jsonb_build_object('nl', $x$Op je tenen$x$, 'en', $x$On your toes$x$)), false, ARRAY[$x$warmup$x$, $x$agility$x$]::text[], ARRAY[$x$u8$x$]::text[], 5),
  ($x$hot-floor-quick-feet$x$, 'basketball', $x$Hot floor$x$, $x$🔥$x$, $x$Quick feet drill$x$, 4, $x$Fast feet, staying light and ready.$x$, ARRAY[$x$Stand with feet shoulder-width apart, knees soft, on your own spot.$x$, $x$Pretend the floor is burning hot — tap your feet up and down as fast as you can without moving forward.$x$, $x$Stay on your toes, pump your arms like you are running in place.$x$, $x$Go fast for 10 seconds, then freeze completely when the coach shouts "Bevries!".$x$, $x$Repeat 3-4 rounds — see who can freeze the stillest.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Snel, snel, snel!$x$, 'en', $x$Fast, fast, fast!$x$), jsonb_build_object('nl', $x$Bevries!$x$, 'en', $x$Freeze!$x$)), false, ARRAY[$x$agility$x$, $x$warmup$x$]::text[], ARRAY[$x$u8$x$]::text[], 6),
  ($x$dynamic-warmup-circuit$x$, 'basketball', $x$Dynamic warm-up circuit$x$, $x$🏃$x$, $x$High knees, butt-kicks, lunges, lateral shuffles$x$, 6, $x$Raise the heart rate and open up hips/ankles like a real practice warm-up.$x$, ARRAY[$x$Line up on the baseline. Down and back on each drill before moving to the next.$x$, $x$High knees: drive knees up fast, pump the arms.$x$, $x$Butt-kicks: heels snap up toward the glutes.$x$, $x$Walking lunge with a torso twist toward the front leg each step.$x$, $x$Lateral shuffle in a low stance, leading with each side on the way back.$x$, $x$Finish with two building-speed strides the length of the court.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Knieën omhoog$x$, 'en', $x$Knees up$x$), jsonb_build_object('nl', $x$Laag blijven$x$, 'en', $x$Stay low$x$)), false, ARRAY[$x$warmup$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 7),
  ($x$reaction-sprint$x$, 'basketball', $x$Reaction sprint$x$, $x$🚦$x$, $x$Coach-call quick starts$x$, 5, $x$Fast first step off an unpredictable signal — game-speed starts, not a countdown.$x$, ARRAY[$x$Players start in an athletic stance on the baseline, facing the coach.$x$, $x$Coach calls a signal at a random moment: a number, a clap, or a color — first move only on the signal.$x$, $x$Sprint to the marked line, jog back, reset stance.$x$, $x$Mix in false signals (a word that is NOT the trigger) to test discipline — no reaction on those.$x$, $x$Rotate through 6-8 reps, resting a few seconds between.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Klaar staan$x$, 'en', $x$Ready position$x$), jsonb_build_object('nl', $x$Nu!$x$, 'en', $x$Go!$x$)), false, ARRAY[$x$warmup$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 8),
  ($x$defensive-slide-ladder$x$, 'basketball', $x$Defensive slide ladder$x$, $x$🛡️$x$, $x$Lateral slides down the sideline and back$x$, 5, $x$Build a low, wide defensive stance into the warm-up instead of adding it later.$x$, ARRAY[$x$Start in a low defensive stance on the sideline: knees bent, chest up, arms wide.$x$, $x$Slide sideways to half-court without crossing your feet or standing up.$x$, $x$Sprint the rest of the way to the far baseline, then jog back.$x$, $x$Repeat leading with the other foot on the way down.$x$, $x$Coach checks stance height and foot-crossing, not just speed.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Voeten niet kruisen$x$, 'en', $x$Don't cross your feet$x$), jsonb_build_object('nl', $x$Laag en breed$x$, 'en', $x$Low and wide$x$)), false, ARRAY[$x$warmup$x$, $x$defense$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 9),
  ($x$partner-mirror-drill$x$, 'basketball', $x$Partner mirror$x$, $x$🪞$x$, $x$Defensive-stance mirroring drill$x$, 6, $x$Read-and-react footwork in a defensive stance, warm-up intensity.$x$, ARRAY[$x$Pair up, facing each other about two steps apart, both in a defensive stance.$x$, $x$Leader moves side to side, forward and back, at a controlled pace; the partner mirrors it, staying square.$x$, $x$Switch leader every 20-30 seconds.$x$, $x$Progression: leader adds a quick fake direction change to test the mirror.$x$, $x$No ball yet — this is about feet and stance, not hands.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Blijf op gelijke hoogte$x$, 'en', $x$Stay level with your partner$x$), jsonb_build_object('nl', $x$Ogen op de heupen$x$, 'en', $x$Eyes on the hips$x$)), false, ARRAY[$x$warmup$x$, $x$defense$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 10),
  ($x$zigzag-sprint$x$, 'basketball', $x$Zig-zag sprint$x$, $x$⚡$x$, $x$Zig zag speed drill$x$, 6, $x$Change of direction and quick cuts.$x$, ARRAY[$x$Set 4-5 cones in a zig-zag line, a few big steps apart.$x$, $x$Sprint to the first cone, then cut sharply toward the next one — no wide loops around the cones.$x$, $x$Stay low and quick through every turn, all the way to the last cone.$x$, $x$Sprint straight through the finish line at the end.$x$, $x$Race a friend, or race the clock for extra fun.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Bocht!$x$, 'en', $x$Turn!$x$), jsonb_build_object('nl', $x$Laag en snel$x$, 'en', $x$Low and fast$x$)), false, ARRAY[$x$agility$x$]::text[], null, 11),
  ($x$break$x$, 'basketball', $x$Water break$x$, $x$🥤$x$, null, 2, $x$Drink, breathe, reset.$x$, ARRAY[$x$Send children to the drinking area.$x$, $x$Keep it short and calm before regrouping.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Drinkpauze$x$, 'en', $x$Water break$x$)), true, '{}'::text[], null, 12),
  ($x$treasure-dribbling$x$, 'basketball', $x$Treasure dribbling$x$, $x$💎$x$, null, 8, $x$Dribbling under light pressure, teamwork, weaker-hand practice.$x$, ARRAY[$x$Put cones or bibs ("the treasure") in the centre. Split children between two home bases.$x$, $x$One child at a time from each team dribbles to the centre, collects one treasure, dribbles back, and high-fives the next player.$x$, $x$Play two or three short rounds. Use the weaker hand for the second round.$x$, $x$Keep score unimportant, or finish with a tie.$x$, $x$If waiting gets long, let two children from each team go at the same time.$x$, $x$Challenge returning players to use their weaker hand. Let beginners carry the treasure while controlling the ball however they can.$x$]::text[], null, false, ARRAY[$x$dribbling$x$, $x$teamplay$x$]::text[], null, 13),
  ($x$figure-8-tunnel$x$, 'basketball', $x$Figure-8 tunnel$x$, $x$♾️$x$, $x$Figure 8 ball-handling drill$x$, 6, $x$Low, controlled dribbling with both hands.$x$, ARRAY[$x$Stand with feet apart and knees bent — your legs are a tunnel for the ball.$x$, $x$Dribble the ball low, push it through the tunnel from front to back with one hand.$x$, $x$Catch it behind your leg with the other hand and bring it around the outside.$x$, $x$Push it through the tunnel again to the front — keep swapping hands.$x$, $x$Keep going non-stop in a figure-8 (∞) shape around both legs.$x$, $x$Challenge: how many figure-8s can you do in 20 seconds without losing the ball?$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Laag blijven$x$, 'en', $x$Stay low$x$), jsonb_build_object('nl', $x$Tunnel!$x$, 'en', $x$Tunnel!$x$)), false, ARRAY[$x$dribbling$x$]::text[], null, 14),
  ($x$two-ball-dribbling$x$, 'basketball', $x$Two-ball dribbling$x$, $x$🏀$x$, $x$Simultaneous two-ball control$x$, 6, $x$Both hands working independently at the same time — a real step up from one-ball control.$x$, ARRAY[$x$Give each player two balls, one per hand.$x$, $x$Dribble both balls at the same height and same rhythm, standing still first.$x$, $x$Progress to alternating rhythm: one ball up while the other is down.$x$, $x$Add movement: walk forward while keeping both balls under control.$x$, $x$Challenge: dribble both balls while walking a zig-zag path around cones.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Twee ballen, één ritme$x$, 'en', $x$Two balls, one rhythm$x$), jsonb_build_object('nl', $x$Ogen omhoog$x$, 'en', $x$Eyes up$x$)), false, ARRAY[$x$dribbling$x$]::text[], ARRAY[$x$u10$x$]::text[], 15),
  ($x$dribble-under-pressure$x$, 'basketball', $x$Dribble under pressure$x$, $x$🥊$x$, $x$Live 1v1 ball protection$x$, 8, $x$Keep control of the ball with a real defender actively trying to poke it away.$x$, ARRAY[$x$Pair up: one player dribbles inside a small grid, the other plays live defense trying to poke the ball away (no grabbing or fouling).$x$, $x$Ball-handler protects the ball with their body, changes hands and speed to keep the defender off balance.$x$, $x$30 seconds per turn, then switch roles.$x$, $x$Coach calls out a bigger or smaller grid to raise or lower the difficulty.$x$, $x$Progression: award a point to the defender for a clean strip, and to the dribbler for surviving the full 30 seconds.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Bal beschermen$x$, 'en', $x$Protect the ball$x$), jsonb_build_object('nl', $x$Verander van snelheid$x$, 'en', $x$Change speed$x$)), false, ARRAY[$x$dribbling$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 16),
  ($x$passing-partners$x$, 'basketball', $x$Passing partners$x$, $x$🤝$x$, null, 10, $x$Chest passing technique and cooperation.$x$, ARRAY[$x$Pair children carefully — ideally a confident child with a newer child. Stand about two large steps apart.$x$, $x$Teach: hands ready like a target, push the ball toward your partner, step toward your partner, call your partner’s name.$x$, $x$Use chest passes first. Allow a bounce pass if it helps a beginner succeed.$x$, $x$Progression: five successful passes → take one step farther apart → pass and move to a new cone.$x$, $x$Challenge: how many good passes can the pair make in 30 seconds?$x$, $x$Do not correct every technical detail — successful cooperation matters most.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Klaar?$x$, 'en', $x$Ready?$x$), jsonb_build_object('nl', $x$Handen klaar$x$, 'en', $x$Hands ready$x$), jsonb_build_object('nl', $x$Stap en duw$x$, 'en', $x$Step and push$x$), jsonb_build_object('nl', $x$Kijk naar je maatje$x$, 'en', $x$Look at your teammate$x$), jsonb_build_object('nl', $x$Goede pass!$x$, 'en', $x$Good pass!$x$)), false, ARRAY[$x$passing$x$]::text[], null, 17),
  ($x$give-and-go-passing$x$, 'basketball', $x$Give-and-go passing$x$, $x$🔁$x$, $x$Pass, cut, receive it back$x$, 8, $x$Passing combined with movement — pass and actually go somewhere, instead of passing and standing still.$x$, ARRAY[$x$Two lines face each other, one ball. Passer passes, then sprints toward the receiver's line.$x$, $x$Receiver catches, immediately passes back to the now-moving cutter (a hand-off or quick chest pass), then follows their own pass.$x$, $x$Keep the ball moving continuously — no standing and holding it.$x$, $x$Progression: add a defender shadowing the cutter without contesting the pass, just to add game realism.$x$, $x$Challenge: how many completed give-and-goes in 60 seconds without a drop?$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Geef en ga!$x$, 'en', $x$Give and go!$x$), jsonb_build_object('nl', $x$Blijf bewegen$x$, 'en', $x$Keep moving$x$)), false, ARRAY[$x$passing$x$, $x$teamplay$x$]::text[], ARRAY[$x$u10$x$]::text[], 18),
  ($x$shooting-form-progression$x$, 'basketball', $x$Shooting form progression$x$, $x$📐$x$, $x$BEEF mechanics, increasing distance$x$, 10, $x$Proper shooting mechanics (Balance, Eyes, Elbow, Follow-through), not just getting the ball in.$x$, ARRAY[$x$Start right under the basket with one-hand form shots: balance on both feet, elbow under the ball, snap the wrist on release, hold the follow-through.$x$, $x$Coach checks each player's elbow and follow-through before letting them move back.$x$, $x$Once form is consistent, step back to the first floor marker and shoot with two hands.$x$, $x$Keep stepping back one marker at a time, only once a player makes 3 in a row from the current spot.$x$, $x$Track each player's furthest "form-approved" distance for next time.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Elleboog eronder$x$, 'en', $x$Elbow underneath$x$), jsonb_build_object('nl', $x$Volg door$x$, 'en', $x$Follow through$x$)), false, ARRAY[$x$shooting$x$]::text[], ARRAY[$x$u10$x$]::text[], 19),
  ($x$shooting-stations$x$, 'basketball', $x$Shooting stations$x$, $x$🏀$x$, null, 10, $x$Everyone shoots, everyone scores, everyone is celebrated.$x$, ARRAY[$x$Split into two groups of four or five. One coach leads each basket.$x$, $x$Station routine: start close to the basket → shoot → collect your own ball → pass to the next child → join the back of the short line.$x$, $x$Use floor markers so children know where to stand.$x$, $x$Simple shooting cue: "Bend, look, push." / "Buig, kijk, duw."$x$, $x$After a few minutes, add a challenge: beginners shoot very close, experienced children take one step back.$x$, $x$Everyone tries to score one basket — celebrate each child’s first basket enthusiastically.$x$, $x$Avoid demanding adult shooting form — success and confidence matter more at this age.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Buig, kijk, duw$x$, 'en', $x$Bend, look, push$x$)), false, ARRAY[$x$shooting$x$]::text[], ARRAY[$x$u8$x$]::text[], 20),
  ($x$layup-merry-go-round$x$, 'basketball', $x$Layup merry-go-round$x$, $x$🔄$x$, $x$Mikan drill — both-hands layup practice$x$, 6, $x$Soft touch layups with both hands, close to the basket.$x$, ARRAY[$x$Stand under the basket, right side of the rim, right foot forward, ball in two hands — no dribble.$x$, $x$Shoot a soft layup off the glass with your right hand.$x$, $x$Catch your own ball before it bounces, and step to the left side of the rim.$x$, $x$Shoot a soft layup off the glass with your left hand.$x$, $x$Keep going non-stop: right, left, right, left — like a merry-go-round.$x$, $x$Challenge: count how many baskets in a row you can make without stopping.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Rechts, links, rechts, links$x$, 'en', $x$Right, left, right, left$x$), jsonb_build_object('nl', $x$Vang je eigen bal$x$, 'en', $x$Catch your own ball$x$)), false, ARRAY[$x$shooting$x$]::text[], null, 21),
  ($x$mini-game$x$, 'basketball', $x$Mini-game: End-zone basketball$x$, $x$🎯$x$, null, 7, $x$Team play, everyone touches the ball.$x$, ARRAY[$x$Play 4-v-4 or 5-v-5 across a small area, using two cone end zones instead of baskets.$x$, $x$A team scores by passing to a teammate standing in the opposing end zone.$x$, $x$Rules: no stealing the ball from someone’s hands; defenders give some space; after receiving the ball, stop and pass; everyone should touch the ball.$x$, $x$Coaches can join in or act as helpers if a team needs support.$x$, $x$Coach lightly — let the game flow. Do not keep a serious score; reset quickly after each point.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Vrij!$x$, 'en', $x$Open!$x$), jsonb_build_object('nl', $x$Passen!$x$, 'en', $x$Pass!$x$), jsonb_build_object('nl', $x$Kijk om je heen$x$, 'en', $x$Look around!$x$), jsonb_build_object('nl', $x$Goed samengespeeld!$x$, 'en', $x$Nice teamwork!$x$), jsonb_build_object('nl', $x$Geef ruimte$x$, 'en', $x$Give space!$x$)), false, ARRAY[$x$teamplay$x$, $x$defense$x$, $x$passing$x$, $x$shooting$x$]::text[], ARRAY[$x$u8$x$]::text[], 22),
  ($x$closeout-defense$x$, 'basketball', $x$Closeout defense$x$, $x$🙅$x$, $x$Sprint, chop, contest$x$, 7, $x$A real defensive skill — closing the distance to a shooter under control and contesting without fouling.$x$, ARRAY[$x$Defender starts under the basket, offensive player waits at the three-point line or floor marker with the ball.$x$, $x$Coach passes to the offensive player; the defender sprints out, then "chops" their feet into a low stance the last two steps — no charging in off balance.$x$, $x$Contest with a high hand, staying low and balanced, without fouling the shooter's arm.$x$, $x$If the shot goes up, box out and go get the rebound.$x$, $x$Rotate through every player on both offense and defense.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Sprint, hak, hak$x$, 'en', $x$Sprint, chop, chop$x$), jsonb_build_object('nl', $x$Hoge hand, geen contact$x$, 'en', $x$High hand, no contact$x$)), false, ARRAY[$x$defense$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 23),
  ($x$live-3v3-halfcourt$x$, 'basketball', $x$Live 3v3 half-court$x$, $x$🏆$x$, $x$Real baskets, live (light-contact) defense$x$, 10, $x$Actual game play with real rules — live defense and real scoring, not end-zone passing.$x$, ARRAY[$x$Play 3v3 half-court to a real basket, normal basketball rules (travels, double dribble called lightly, no reaching-in fouls).$x$, $x$Defenders may contest shots and passing lanes but no grabbing or hand-checking.$x$, $x$Make it call your own fouls — this age can start handling that responsibility.$x$, $x$Play to a low target score (e.g. first to 7) so groups rotate through quickly.$x$, $x$Coach steps back and only intervenes for safety or to reset an argument, letting the game teach itself.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Speel eerlijk$x$, 'en', $x$Play fair$x$), jsonb_build_object('nl', $x$Kom terug in verdediging$x$, 'en', $x$Get back on defense$x$)), false, ARRAY[$x$teamplay$x$, $x$defense$x$, $x$passing$x$, $x$shooting$x$]::text[], ARRAY[$x$u10$x$]::text[], 24),
  ($x$team-finish$x$, 'basketball', $x$Team finish$x$, $x$🎉$x$, null, 3, $x$Reflect together and celebrate as a team.$x$, ARRAY[$x$Gather in a circle, balls still on the floor.$x$, $x$Ask: "Wat vond je leuk? / What did you enjoy?"$x$, $x$Ask: "Wie heeft vandaag iets nieuws geprobeerd? / Who tried something new?"$x$, $x$Finish with everyone putting one hand in: "Team on three! Eén, twee, drie — TEAM!"$x$, $x$Invite the children to show parents one favourite move, or take a final group shot while parents cheer.$x$]::text[], null, false, ARRAY[$x$teamplay$x$, $x$warmup$x$]::text[], null, 25)
on conflict (id) do nothing;

-- Additional u10 exercises (sports-training-api#59) — passing/shooting/footwork drills were
-- thin for u10 (1 each). Concepts loosely inspired by the age-tiered structure of published
-- youth basketball curricula (e.g. Jr. NBA's Rookie/Starter practice plans use the same
-- warm-up/ball-handling/passing/shooting/defense breakdown) but every description, step, and
-- cue below is written independently — no external text, images, or video reproduced. Drill
-- concepts like "wall target passing" or "catch and pivot" are generic basketball fundamentals
-- used across virtually every coaching curriculum, not anyone's protected expression.
insert into exercises (id, sport_id, title, emoji, subtitle, duration_minutes, goal, steps, cues, is_break, categories, groups, sort_order) values
  ($x$wall-target-passing$x$, 'basketball', $x$Wall target passing$x$, $x$🧱$x$, $x$Chest pass reps against a wall target$x$, 6, $x$Repetition builds accurate chest-pass mechanics without needing a partner to chase down bad passes.$x$, ARRAY[$x$Each player stands a few steps from a wall and picks a target — a mark, a piece of tape, or a painted line.$x$, $x$Step toward the target with the lead foot, push the ball out with both thumbs, and snap the wrist down on release.$x$, $x$Let the pass bounce once off the wall, catch it, and reset.$x$, $x$Once accuracy is solid, add one dribble before each pass to link movement and passing.$x$, $x$Increase distance from the wall only once a player is consistently hitting the target.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Stap naar het doel$x$, 'en', $x$Step to the target$x$), jsonb_build_object('nl', $x$Duimen naar beneden$x$, 'en', $x$Thumbs down$x$)), false, ARRAY[$x$passing$x$]::text[], ARRAY[$x$u10$x$]::text[], 26),
  ($x$call-and-catch-passing$x$, 'basketball', $x$Call-and-catch passing$x$, $x$📣$x$, $x$Passing to a moving, named target$x$, 7, $x$Passing under a small decision — who, where, when — instead of a fixed repetitive target.$x$, ARRAY[$x$Three players form a triangle a few steps apart, one ball.$x$, $x$Passer calls a teammate's name before releasing the ball, so the receiver knows it's coming to them.$x$, $x$Receiver squares up, catches with both hands, and immediately becomes the next passer.$x$, $x$After a few rounds, players may shuffle sideways between passes so the target keeps moving.$x$, $x$Progression: passer must use a different pass type (chest, bounce, overhead) each time.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Zeg de naam!$x$, 'en', $x$Call the name!$x$), jsonb_build_object('nl', $x$Kijk voor je passt$x$, 'en', $x$Look before you pass$x$)), false, ARRAY[$x$passing$x$, $x$agility$x$]::text[], ARRAY[$x$u10$x$]::text[], 27),
  ($x$cone-collector-shooting$x$, 'basketball', $x$Cone collector$x$, $x$🚩$x$, $x$Team shooting game — claim a cone for every make$x$, 8, $x$Turns shooting reps into a team race so players want the extra shot instead of dreading it.$x$, ARRAY[$x$Scatter 8-10 cones around the half-court at mixed distances, closer ones worth less.$x$, $x$Split into two or three teams, each lined up with one ball.$x$, $x$First player dribbles to any open cone and shoots from that spot.$x$, $x$A make means the player carries that cone back to their team; a miss means the cone stays and they hustle back empty-handed.$x$, $x$Next player in line goes as soon as the ball or cone is back — keep the line moving.$x$, $x$Game ends when all cones are claimed; most cones (or highest cone value) wins.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Kies je kegel$x$, 'en', $x$Pick your cone$x$), jsonb_build_object('nl', $x$Goede vorm, ook onder druk$x$, 'en', $x$Good form, even under pressure$x$)), false, ARRAY[$x$shooting$x$, $x$teamplay$x$]::text[], ARRAY[$x$u10$x$]::text[], 28),
  ($x$one-count-catch-shoot$x$, 'basketball', $x$One-count catch and shoot$x$, $x$⏱️$x$, $x$Catch, set, shoot — no extra dribble$x$, 6, $x$Builds the habit of shooting quickly off a pass instead of catching and dribbling every time.$x$, ARRAY[$x$Pairs stand a few steps apart around the arc, one ball.$x$, $x$Passer feeds a chest pass; receiver catches with feet already stepping into a shooting stance.$x$, $x$Shooter releases within one count of catching the ball — no dribble.$x$, $x$Rebound your own miss or make, pass back, and switch roles after five shots.$x$, $x$Coach checks that the catch, step, and shot happen as one smooth motion, not three separate stops.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Vang en schiet$x$, 'en', $x$Catch and shoot$x$), jsonb_build_object('nl', $x$Voeten klaar voor de vangst$x$, 'en', $x$Feet ready before the catch$x$)), false, ARRAY[$x$shooting$x$]::text[], ARRAY[$x$u10$x$]::text[], 29),
  ($x$quick-taps-ball-control$x$, 'basketball', $x$Quick taps$x$, $x$👐$x$, $x$Fast fingertip ball control warm-up$x$, 4, $x$Wakes up the hands and fingertips before the main session — pure ball feel, no pressure to perform.$x$, ARRAY[$x$Each player holds a ball at chest height and taps it quickly hand to hand using only the fingertips.$x$, $x$After 20 taps, move the tapping motion up overhead, then down around the knees, then around the waist.$x$, $x$Keep the taps quick and light — the ball should barely leave the fingertips.$x$, $x$Challenge: close your eyes for five taps and feel the ball instead of watching it.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Alleen vingertoppen$x$, 'en', $x$Fingertips only$x$), jsonb_build_object('nl', $x$Snel en licht$x$, 'en', $x$Quick and light$x$)), false, ARRAY[$x$warmup$x$, $x$dribbling$x$]::text[], ARRAY[$x$u10$x$]::text[], 30),
  ($x$catch-and-pivot$x$, 'basketball', $x$Catch and pivot$x$, $x$🔄$x$, $x$Footwork after the catch — plant a pivot foot and look$x$, 6, $x$Establishes a legal, balanced pivot foot the moment the ball is caught, before adding any pressure.$x$, ARRAY[$x$Partners face each other a few steps apart, one ball.$x$, $x$Receiver catches the pass with both feet on the ground, then picks one foot as the pivot and keeps it planted.$x$, $x$Using the free foot, the receiver pivots forward and backward, staying balanced and keeping the ball protected near the chest.$x$, $x$After five pivots, the receiver passes back and switches roles.$x$, $x$Progression: coach calls "Forward!" or "Reverse!" so the player pivots on command instead of freely.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Kies je spilvoet$x$, 'en', $x$Pick your pivot foot$x$), jsonb_build_object('nl', $x$Bal dicht bij de borst$x$, 'en', $x$Ball close to your chest$x$)), false, ARRAY[$x$dribbling$x$, $x$passing$x$]::text[], ARRAY[$x$u10$x$]::text[], 31)
on conflict (id) do nothing;

-- Additional u8 exercises (sports-training-api#59) — passing had only 1 shared drill and
-- defense had none dedicated for this age (only touched lightly inside mini-game). Written in
-- the same playful, game-first tone as the existing u8 rows above (Wall of China, Mario jump
-- crab cheetah, etc). No external text, images, or video reproduced — see the u10 block above
-- for the sourcing note.
insert into exercises (id, sport_id, title, emoji, subtitle, duration_minutes, goal, steps, cues, is_break, categories, groups, sort_order) values
  ($x$sticky-hands-passing$x$, 'basketball', $x$Sticky hands passing$x$, $x$🖐️$x$, $x$Playful partner passing — catch it before it "escapes"$x$, 5, $x$Turns basic catching into a game so young players want to catch cleanly instead of fearing the ball.$x$, ARRAY[$x$Pair up two steps apart, one ball, a coach or parent nearby to help beginners.$x$, $x$Teach "sticky hands": fingers spread wide, hands come up to meet the ball before it arrives.$x$, $x$Passer uses a soft two-hand chest pass; catcher shouts "Got it!" the moment the ball sticks to their hands.$x$, $x$After five clean catches in a row, take one small step farther apart.$x$, $x$If the ball keeps dropping, move a step closer instead — success feels better than distance.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Plakhanden!$x$, 'en', $x$Sticky hands!$x$), jsonb_build_object('nl', $x$Handen omhoog$x$, 'en', $x$Hands up$x$)), false, ARRAY[$x$passing$x$]::text[], ARRAY[$x$u8$x$]::text[], 26),
  ($x$pass-the-treasure-circle$x$, 'basketball', $x$Pass the treasure circle$x$, $x$💎$x$, $x$Whole-group passing game in a circle$x$, 6, $x$Gets every child passing and catching in a low-pressure group format instead of waiting in a long line.$x$, ARRAY[$x$Whole group stands in a big circle, one ball to start.$x$, $x$The player with the ball calls the name of anyone across the circle and passes to them.$x$, $x$Receiver says "thank you" and picks a new name to pass to next.$x$, $x$After a minute, add a second ball to the circle so two passes are happening at once.$x$, $x$If a pass is dropped, just pick it up and keep going — never stop the game to fix it.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Zeg een naam!$x$, 'en', $x$Call a name!$x$), jsonb_build_object('nl', $x$Dank je!$x$, 'en', $x$Thank you!$x$)), false, ARRAY[$x$passing$x$, $x$teamplay$x$]::text[], ARRAY[$x$u8$x$]::text[], 27),
  ($x$shadow-guard$x$, 'basketball', $x$Shadow guard$x$, $x$👻$x$, $x$First taste of guarding — stay between your buddy and the "basket"$x$, 5, $x$Introduces the idea of defense — staying in front of someone — as a fun shadowing game, no contact or ball skill required yet.$x$, ARRAY[$x$Pair up. One cone marks the "basket" a few steps behind one partner.$x$, $x$Attacker tries to walk or jog around their partner to touch the cone; defender slides sideways to always stay between the attacker and the cone.$x$, $x$No tagging, no grabbing — just feet and staying in the way, like a friendly shadow.$x$, $x$Switch roles after 30 seconds.$x$, $x$Coach cue: stay low, small quick steps, arms out wide like a spider.$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Blijf ertussen!$x$, 'en', $x$Stay in between!$x$), jsonb_build_object('nl', $x$Kleine pasjes$x$, 'en', $x$Small steps$x$)), false, ARRAY[$x$defense$x$, $x$agility$x$]::text[], ARRAY[$x$u8$x$]::text[], 28),
  ($x$bucket-buddies$x$, 'basketball', $x$Bucket buddies$x$, $x$🏅$x$, $x$Partner shooting game — cheer every attempt$x$, 6, $x$Builds shot confidence at this age through cheering and turn-taking, not corrections.$x$, ARRAY[$x$Pair up at a basket, one ball between two.$x$, $x$Shooter takes a shot from a close, comfortable spot; partner rebounds and passes it back.$x$, $x$After every attempt — make or miss — the partner shouts "Nice shot!" before switching turns.$x$, $x$After five turns each, the shooter takes one small step back if they are making most shots.$x$, $x$Coach cue stays simple: "Buig, kijk, duw" / "Bend, look, push."$x$]::text[], jsonb_build_array(jsonb_build_object('nl', $x$Leuk schot!$x$, 'en', $x$Nice shot!$x$), jsonb_build_object('nl', $x$Wissel!$x$, 'en', $x$Switch!$x$)), false, ARRAY[$x$shooting$x$]::text[], ARRAY[$x$u8$x$]::text[], 29)
on conflict (id) do nothing;

-- ============================================================================================
-- Parent codes (sports-training-api#20) — a trainer-issued code, scoped to one player, that
-- unlocks a read-only view for that child's parent. Deliberately reuses the existing
-- "pick a group, enter a code" LockScreen flow rather than a separate parent screen or a
-- `parents` table with its own identity — same code-based, no-real-contact-info approach as
-- the trainer passcode, consistent with this app's GDPR-light stance (see PRIVACY_NOTICE in
-- the UI repo).
-- ============================================================================================

alter table players add column if not exists parent_code text;

-- Global uniqueness (not just per-group) means a code alone identifies exactly one player;
-- verify_group_access below still checks it against the entered group, so a code only ever
-- works within the group it was issued for.
create unique index if not exists players_parent_code_unique_idx on players (parent_code)
  where parent_code is not null;

-- NEVER select parent_code in a public players listing — it's a secret, same principle as
-- groups.passcode above. src/routes/players.ts must explicitly list columns rather than
-- select('*') and must never echo the raw code back except right after issuing/regenerating it.

-- Given a group + a code entered on the LockScreen, resolves whether it's the group's trainer
-- passcode or one player's parent code within that group — and if a parent code, which player.
-- Zero rows = no match; exactly one row otherwise. Replaces the old boolean verify_passcode()
-- for the /auth/verify-passcode endpoint specifically; verify_passcode() itself is unchanged
-- and still used internally by the trainer-only mutation functions below.
create or replace function verify_group_access(p_group_id text, input text)
returns table (kind text, player_id uuid, player_nickname text)
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from groups where id = p_group_id and passcode = input) then
    return query select 'trainer'::text, null::uuid, null::text;
    return;
  end if;
  return query
    select 'parent'::text, p.id, p.nickname
    from players p
    where p.group_id = p_group_id and p.parent_code = input;
end;
$$;

grant execute on function verify_group_access(text, text) to anon;

-- Trainer issues/regenerates/revokes a player's parent code (p_code null revokes) — gated by
-- the player's own group's trainer passcode, same pattern as update_player/delete_player. The
-- actual random code is generated in the API layer (see src/routes/players.ts), which retries
-- on the rare unique-index collision; this function just applies whatever code it's given.
create or replace function set_player_parent_code(passcode text, p_id uuid, p_code text)
returns players
language plpgsql
security definer
set search_path = public
as $$
declare
  result players;
  v_group_id text;
begin
  select group_id into v_group_id from players where id = p_id;
  if v_group_id is null then
    raise exception 'Player not found';
  end if;
  if not verify_passcode(v_group_id, passcode) then
    raise exception 'invalid passcode';
  end if;
  update players set parent_code = p_code, updated_at = now() where id = p_id returning * into result;
  return result;
end;
$$;

grant execute on function set_player_parent_code(text, uuid, text) to anon;

-- Mascot artwork resolution by sport + age range (#72) — replaces the fixed
-- stage in ('baby','child','teen','adult') CHECK on mascot_avatars, and moves sport/age off
-- group_templates inheritance and onto groups directly, so a future renamed or fully custom
-- club group (no template) still resolves to the right artwork. Placeholder age numbers
-- throughout — the point is the mechanism, not the boundaries; adjust later without a
-- migration. Already applied directly via the Supabase SQL editor; this codifies it here as
-- the tracked source of truth.

-- 1. The finite set of art buckets (baby/child/teen/adult) as real, editable data instead
--    of a hardcoded CHECK constraint.
create table if not exists mascot_stages (
  id text primary key,
  label text not null,
  min_age int not null,
  max_age int,                -- null = open-ended (adult)
  sort_order int not null default 0
);

insert into mascot_stages (id, label, min_age, max_age, sort_order) values
  ('baby', 'Baby', 0, 8, 1),
  ('child', 'Child', 8, 10, 2),
  ('teen', 'Teen', 10, 14, 3),
  ('adult', 'Adult', 14, null, 4)
on conflict (id) do nothing;

-- Corrected/expanded per the actual mascot art plan: 7 stages instead of 4, matching the age
-- bands artwork will be produced for. 'teen' narrows from 10-14 down to 10-12; 'adult' is
-- repurposed into 'grownup' at 18+ (safe -- no mascot_avatars row used stage='adult'); three
-- new stages (puber/mid-teens/adolescence) fill the 12-18 range the old 'teen'/'adult' pair
-- didn't distinguish. The seed above uses `on conflict do nothing`, so it never touches
-- existing rows -- these are explicit corrections instead. Already applied directly via the
-- Supabase SQL editor; this codifies it here as the tracked source of truth.
update mascot_stages set min_age = 10, max_age = 12 where id = 'teen';
update mascot_stages set id = 'grownup', label = 'Grownup', min_age = 18, max_age = null, sort_order = 7
  where id = 'adult';

insert into mascot_stages (id, label, min_age, max_age, sort_order) values
  ('puber', 'Puberty', 12, 14, 4),
  ('mid-teens', 'Mid-Teens', 14, 16, 5),
  ('adolescence', 'Adolescence', 16, 18, 6)
on conflict (id) do nothing;

alter table mascot_stages enable row level security;

drop policy if exists "mascot stages are publicly readable" on mascot_stages;
create policy "mascot stages are publicly readable" on mascot_stages
  for select using (true);

grant select on mascot_stages to anon;
revoke insert, update, delete on mascot_stages from anon;

-- 2. mascot_avatars.stage: swap the inline CHECK for an FK into mascot_stages, same column,
--    same shape everywhere else that reads it.
alter table mascot_avatars drop constraint if exists mascot_avatars_stage_check;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'mascot_avatars_stage_fkey'
  ) then
    alter table mascot_avatars add constraint mascot_avatars_stage_fkey
      foreign key (stage) references mascot_stages(id);
  end if;
end $$;

-- 3. group_templates gets its own age range (mirrors the existing mascot_stage column,
--    which this eventually supersedes) so a group created from a template still gets a
--    sane default.
alter table group_templates add column if not exists min_age int;
alter table group_templates add column if not exists max_age int;

update group_templates set min_age = 0, max_age = 8 where id = 'u8';
update group_templates set min_age = 8, max_age = 10 where id = 'u10';
update group_templates set min_age = 10, max_age = 12 where id = 'u12';
update group_templates set min_age = 12, max_age = 14 where id = 'u14';
update group_templates set min_age = 14, max_age = 16 where id = 'u16';
update group_templates set min_age = 16, max_age = 18 where id = 'u18';
update group_templates set min_age = 18, max_age = null where id = 'grownup';

-- 4. groups gets sport_id + age range directly — not inherited through template_id, so a
--    future custom club group (no template) still resolves to the right art.
alter table groups add column if not exists sport_id text references sports(id);
alter table groups add column if not exists min_age int;
alter table groups add column if not exists max_age int;

update groups g
set sport_id = t.sport_id,
    min_age = t.min_age,
    max_age = t.max_age
from group_templates t
where g.template_id = t.id
  and (g.sport_id is null or g.min_age is null or g.max_age is null);

-- sport_id should always be set going forward (age range can stay null until a group's
-- age band is actually known/decided). SET NOT NULL is itself idempotent -- safe to re-run.
alter table groups alter column sport_id set not null;

-- Adds a jersey_color dimension to mascot_avatars and seeds the 8 existing Leon basketball
-- images as real rows (#47). mascot_avatars previously keyed artwork by
-- (mascot_id, sport_id, stage) only -- but the art that actually exists (sports-training-ui's
-- 8 jersey colors) isn't a single pose recolored 8 ways, each color is a genuinely different
-- illustration (see JerseyGraphic.tsx's per-color NUMBER_LAYOUT). Life-stage and jersey color
-- are both real, independent axes: stage says how mature the mascot looks as a kid moves up
-- through age groups, color is the player's own pick. Already applied directly via the
-- Supabase SQL editor; this codifies it here as the tracked source of truth.

-- jersey_color is nullable -- a future sport/stage might not need color variants at all
-- (single universal art), in which case it stays null and lookup matches on
-- (mascot_id, sport_id, stage) alone.
alter table mascot_avatars add column if not exists jersey_color text;

alter table mascot_avatars drop constraint if exists mascot_avatars_mascot_id_sport_id_stage_key;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'mascot_avatars_mascot_sport_stage_color_key'
  ) then
    alter table mascot_avatars add constraint mascot_avatars_mascot_sport_stage_color_key
      unique (mascot_id, sport_id, stage, jersey_color);
  end if;
end $$;

-- Seed the 8 existing Leon basketball images -- stage='child' since that's the only stage
-- with art today (this is U8/U10 territory). image_url is relative, matching the
-- clubs.logo_url convention (frontend prefixes with import.meta.env.BASE_URL) -- same encoded
-- path sports-training-ui's JerseyGraphic.tsx already uses for these exact files.
insert into mascot_avatars (mascot_id, sport_id, stage, jersey_color, image_url) values
  ('lion', 'basketball', 'child', 'orange', 'images/basketball/u8%20u10/Leon/Web%20size/leon-orange.webp'),
  ('lion', 'basketball', 'child', 'blue',   'images/basketball/u8%20u10/Leon/Web%20size/leon-blue.webp'),
  ('lion', 'basketball', 'child', 'red',    'images/basketball/u8%20u10/Leon/Web%20size/leon-red.webp'),
  ('lion', 'basketball', 'child', 'green',  'images/basketball/u8%20u10/Leon/Web%20size/leon-green.webp'),
  ('lion', 'basketball', 'child', 'purple', 'images/basketball/u8%20u10/Leon/Web%20size/leon-purple.webp'),
  ('lion', 'basketball', 'child', 'black',  'images/basketball/u8%20u10/Leon/Web%20size/leon-black.webp'),
  ('lion', 'basketball', 'child', 'white',  'images/basketball/u8%20u10/Leon/Web%20size/leon-white.webp'),
  ('lion', 'basketball', 'child', 'yellow', 'images/basketball/u8%20u10/Leon/Web%20size/leon-yellow.webp')
on conflict (mascot_id, sport_id, stage, jersey_color) do update set image_url = excluded.image_url;

-- Extends #47's seed to also cover stage='baby' with the same 8 images (#49) -- no dedicated
-- baby art yet, and U8 maps to 'baby' per group_templates, so without this U8 groups resolved
-- to zero mascot_avatars rows even though 'child' (U10) had art. Already applied directly via
-- the Supabase SQL editor; this codifies it here as the tracked source of truth.
insert into mascot_avatars (mascot_id, sport_id, stage, jersey_color, image_url) values
  ('lion', 'basketball', 'baby', 'orange', 'images/basketball/u8%20u10/Leon/Web%20size/leon-orange.webp'),
  ('lion', 'basketball', 'baby', 'blue',   'images/basketball/u8%20u10/Leon/Web%20size/leon-blue.webp'),
  ('lion', 'basketball', 'baby', 'red',    'images/basketball/u8%20u10/Leon/Web%20size/leon-red.webp'),
  ('lion', 'basketball', 'baby', 'green',  'images/basketball/u8%20u10/Leon/Web%20size/leon-green.webp'),
  ('lion', 'basketball', 'baby', 'purple', 'images/basketball/u8%20u10/Leon/Web%20size/leon-purple.webp'),
  ('lion', 'basketball', 'baby', 'black',  'images/basketball/u8%20u10/Leon/Web%20size/leon-black.webp'),
  ('lion', 'basketball', 'baby', 'white',  'images/basketball/u8%20u10/Leon/Web%20size/leon-white.webp'),
  ('lion', 'basketball', 'baby', 'yellow', 'images/basketball/u8%20u10/Leon/Web%20size/leon-yellow.webp')
on conflict (mascot_id, sport_id, stage, jersey_color) do update set image_url = excluded.image_url;

-- First entry for stage='teen' (U12 territory) -- reuses the same white jersey image as a
-- stopgap, since no dedicated teen art exists yet. Already applied directly via the Supabase
-- SQL editor; this codifies it here as the tracked source of truth.
insert into mascot_avatars (mascot_id, sport_id, stage, jersey_color, image_url) values
  ('lion', 'basketball', 'teen', 'white', 'images/basketball/u8%20u10/Leon/Web%20size/leon-white.webp')
on conflict (mascot_id, sport_id, stage, jersey_color) do update set image_url = excluded.image_url;

-- First dedicated stage='child' (U10) art -- a genuinely different pose/illustration than
-- 'baby', not the shared stopgap seeded above (see sports-training-ui#77). Only orange/white
-- exist so far; the other 6 colors keep resolving to the 'baby'-shared image above until their
-- own dedicated art is ready. sports-training-ui's JerseyGraphic.tsx resolves this pose's
-- distinct canvas/chest-plate placement via a stage-aware layout override keyed on
-- stage='child', not the flat per-color table used by the shared art.
insert into mascot_avatars (mascot_id, sport_id, stage, jersey_color, image_url) values
  ('lion', 'basketball', 'child', 'orange', 'images/basketball/u8%20u10/Leon/Web%20size/leon-child-orange.webp'),
  ('lion', 'basketball', 'child', 'white',  'images/basketball/u8%20u10/Leon/Web%20size/leon-child-white.webp')
on conflict (mascot_id, sport_id, stage, jersey_color) do update set image_url = excluded.image_url;

-- Dynamic multiply-blend mascot art for stage='baby' (sports-training-api#57/#59) -- replaces
-- the 8 shared-stopgap jersey_color rows for this stage with 2 real rows, one per gender, each
-- holding a single grayscale-ready base pose plus mask assets for the regions that get
-- recolored client-side via CSS `mix-blend-mode: multiply` (see JerseyGraphic.tsx), instead of
-- one fully-baked image per jersey color. Only jersey(+shorts+shoes) and eyes are dynamic so
-- far -- mane/fur/sweatband stay fixed as painted, per issue #57's phased scope. Every mask
-- asset and layout box below was traced/measured directly in Figma
-- (J9dSOUC5az7RoMJlNegRtr, node 4008:346), not eyeballed.
--
-- jersey_color stays null on these rows (color is chosen per-player at render time, not baked
-- into the row) -- the existing (mascot_id, sport_id, stage, jersey_color) unique constraint
-- still holds since Postgres never treats two NULLs as conflicting; gender is what makes these
-- two rows distinct from each other, enforced by its own partial unique index below.
alter table mascot_avatars add column if not exists gender text check (gender in ('boy', 'girl'));

-- {left, top, width, height} as fractions of the base image (0-1), for CSS absolute
-- positioning of a mask/overlay image on top of it. All four layout columns share this shape.
alter table mascot_avatars add column if not exists jersey_mask_url text;
alter table mascot_avatars add column if not exists jersey_layout jsonb;
alter table mascot_avatars add column if not exists eyes_mask_url text;
alter table mascot_avatars add column if not exists eyes_layout jsonb;
-- Number and logo have no _mask_url -- they're not colored regions, just placement boxes the
-- app draws its own <text>/logo image into (see NUMBER_LAYOUT precedent in JerseyGraphic.tsx).
alter table mascot_avatars add column if not exists number_layout jsonb;
alter table mascot_avatars add column if not exists logo_layout jsonb;

do $$
begin
  if not exists (
    select 1 from pg_indexes where indexname = 'mascot_avatars_gender_key'
  ) then
    create unique index mascot_avatars_gender_key
      on mascot_avatars (mascot_id, sport_id, stage, gender)
      where gender is not null;
  end if;
end $$;

-- Retires the 8 shared-stopgap 'baby' rows seeded above (#49) -- they pointed every color at
-- the same placeholder image since no dedicated baby art existed yet. Real art now exists, so
-- keeping both would make GET /mascots/avatars return two conflicting resolutions for the same
-- stage (a flat per-color row AND a per-gender dynamic row). Not a Law-8-style file deletion --
-- just retiring rows this same migration file's own earlier insert created as a stopgap.
delete from mascot_avatars
  where mascot_id = 'lion' and sport_id = 'basketball' and stage = 'baby' and jersey_color is not null;

insert into mascot_avatars
  (mascot_id, sport_id, stage, gender, image_url, jersey_mask_url, jersey_layout, eyes_mask_url, eyes_layout, number_layout, logo_layout)
values
  (
    'lion', 'basketball', 'baby', 'boy',
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-boy.webp',
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-jersey-{color}.svg',
    '{"left": 0.13815, "top": 0.43723, "width": 0.72415, "height": 0.51805}'::jsonb,
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-eyes-{color}.svg',
    '{"left": 0.36275, "top": 0.25678, "width": 0.27807, "height": 0.10449}'::jsonb,
    '{"left": 0.41800, "top": 0.53281, "width": 0.15597, "height": 0.12482}'::jsonb,
    '{"left": 0.38324, "top": 0.49287, "width": 0.07388, "height": 0.04708}'::jsonb
  ),
  (
    'lion', 'basketball', 'baby', 'girl',
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-girl.webp',
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-jersey-{color}.svg',
    '{"left": 0.13815, "top": 0.43723, "width": 0.72415, "height": 0.51805}'::jsonb,
    'images/basketball/u8%20u10/Leon/Web%20size/leon-baby-eyes-{color}.svg',
    '{"left": 0.36275, "top": 0.25678, "width": 0.27807, "height": 0.10449}'::jsonb,
    '{"left": 0.41800, "top": 0.53281, "width": 0.15597, "height": 0.12482}'::jsonb,
    '{"left": 0.38324, "top": 0.49287, "width": 0.07388, "height": 0.04708}'::jsonb
  )
on conflict (mascot_id, sport_id, stage, gender) where gender is not null
  do update set
    image_url = excluded.image_url,
    jersey_mask_url = excluded.jersey_mask_url,
    jersey_layout = excluded.jersey_layout,
    eyes_mask_url = excluded.eyes_mask_url,
    eyes_layout = excluded.eyes_layout,
    number_layout = excluded.number_layout,
    logo_layout = excluded.logo_layout;

-- Also need the shared highlight-dots layer (always plain white, never multiply-blended --
-- multiplying white is a no-op, which would make the eye shine vanish) and the eye-color
-- palette itself, both fixed per pose rather than per (mascot,gender) row. Small enough to
-- live as app-side constants in JerseyGraphic.tsx instead of their own columns -- see that
-- file's EYE_COLORS/ EYE_HIGHLIGHTS_URL.
