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
create table if not exists group_templates (
  id text primary key,
  sport_id text not null references sports(id),
  label text not null,
  emoji text not null default '🏀',
  status text not null default 'available' check (status in ('available', 'coming_soon')),
  sort_order int not null default 0
);

insert into group_templates (id, sport_id, label, emoji, status, sort_order) values
  ('u8', 'basketball', 'U8', '🏀', 'available', 1),
  ('u10', 'basketball', 'U10', '🏀', 'available', 2),
  ('u12', 'basketball', 'U12', '🏀', 'coming_soon', 3),
  ('u14', 'basketball', 'U14', '🏀', 'coming_soon', 4)
on conflict (id) do nothing;

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
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Backfill for existing installs where `players` was created before these columns existed.
alter table players add column if not exists jersey_number int;
alter table players add column if not exists jersey_color text;
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

create or replace function create_player(
  passcode text,
  p_group_id text,
  p_nickname text,
  p_jersey_number int default null,
  p_jersey_color text default null
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
  insert into players (group_id, nickname, jersey_number, jersey_color)
  values (p_group_id, p_nickname, p_jersey_number, p_jersey_color)
  returning * into result;
  return result;
end;
$$;

-- Reassigning to a new group only requires the passcode for the player's CURRENT group —
-- moving a promoted player into U10 doesn't require already knowing U10's code.
drop function if exists update_player(text, uuid, text, text);

create or replace function update_player(
  passcode text,
  p_id uuid,
  p_group_id text,
  p_nickname text,
  p_jersey_number int default null,
  p_jersey_color text default null
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

grant execute on function create_player(text, text, text, int, text) to anon;
grant execute on function update_player(text, uuid, text, text, int, text) to anon;
grant execute on function delete_player(text, uuid) to anon;

-- Skill categories a player's progress can be rated on — same taxonomy as training categories
-- (src/data/categories.ts in the UI repo) minus 'warmup', so progress ratings and training
-- content share one vocabulary. 'agility' doubles as the stamina/conditioning bucket.
create table if not exists skill_categories (
  id text primary key,
  sport_id text not null references sports(id),
  label text not null,
  emoji text not null,
  sort_order int not null default 0
);

insert into skill_categories (id, sport_id, label, emoji, sort_order) values
  ('dribbling', 'basketball', 'Dribbling', '⛹️', 1),
  ('passing', 'basketball', 'Passing', '🤝', 2),
  ('shooting', 'basketball', 'Shooting', '🎯', 3),
  ('defense', 'basketball', 'Defense & Movement', '🛡️', 4),
  ('agility', 'basketball', 'Agility & Stamina', '🏃', 5),
  ('teamplay', 'basketball', 'Team Play & Game', '🏆', 6)
on conflict (id) do nothing;

alter table skill_categories enable row level security;

drop policy if exists "skill categories are publicly readable" on skill_categories;
create policy "skill categories are publicly readable" on skill_categories
  for select using (true);

grant select on skill_categories to anon;
revoke insert, update, delete on skill_categories from anon;

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
