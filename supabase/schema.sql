-- Source of truth for the Supabase schema — run this once in the Supabase project's SQL
-- editor (Project -> SQL Editor -> New query). Owned here, not in the frontend repo, since
-- this API is the only thing that talks to Supabase (see README.md).
--
-- Shared, dated training plans for U8 Basketball Training, writable by any trainer who knows
-- the team passcode. Reads are public; writes go through passcode-checked RPC functions only
-- (the passcode itself is never exposed to the browser) — this API fronts those RPCs, see
-- src/routes/plans.ts.
--
-- GDPR note (see basketball/PRIVACY.md in the frontend repo): this schema intentionally
-- stores NO personal data at all — no names, emails, or anything identifying a trainer or a
-- child, just plan dates and which exercises they contain. When creating the Supabase
-- project, pick an EU region (e.g. Frankfurt / eu-central-1) to keep data residency in the
-- EU/EEA for when that changes.

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
--
-- Sport lives on the GROUP, not here: a Dutch club (vereniging) commonly runs several sport
-- sections under one roof (Dunckers could add a hockey or korfbal afdeling later), so the
-- club itself stays sport-agnostic. Groups aren't a DB table yet (see src/data/groups.ts —
-- still a client-side config list), so that's where sportId lives for now.
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

create table if not exists plans (
  id uuid primary key default gen_random_uuid(),
  group_id text not null,
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

create table if not exists app_config (
  key text primary key,
  value text not null
);

-- Seed the shared trainer passcode. CHANGE THIS after running the script:
-- update app_config set value = 'your-own-code' where key = 'team_passcode';
insert into app_config (key, value)
values ('team_passcode', 'changeme')
on conflict (key) do nothing;

alter table plans enable row level security;
alter table app_config enable row level security;

-- Anyone can read the list of planned trainings.
drop policy if exists "plans are publicly readable" on plans;
create policy "plans are publicly readable" on plans
  for select using (true);

-- No select policy on app_config at all: the passcode is never readable directly,
-- only checked server-side through verify_passcode() below.

-- Checks a passcode against the stored value without ever returning it.
create or replace function verify_passcode(input text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from app_config where key = 'team_passcode' and value = input
  );
$$;

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
  if not verify_passcode(passcode) then
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
begin
  if not verify_passcode(passcode) then
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
begin
  if not verify_passcode(passcode) then
    raise exception 'invalid passcode';
  end if;
  delete from plans where id = p_id;
end;
$$;

-- The anon (public) role may only read plans directly, and mutate only via the
-- passcode-checked RPCs above — it has no direct insert/update/delete grant.
grant select on plans to anon;
revoke insert, update, delete on plans from anon;
grant execute on function verify_passcode(text) to anon;
grant execute on function create_plan(text, text, date, text, text, text[]) to anon;
grant execute on function update_plan(text, uuid, date, text, text, text[]) to anon;
grant execute on function delete_plan(text, uuid) to anon;

-- One row per group: the shared, live session clock every trainer's device polls and controls,
-- so starting/pausing/skipping on one phone shows up on everyone else's within a couple of
-- seconds. `elapsed_seconds` is the accumulated time as of the last start/pause/seek;
-- `running_since` is only set while status = 'running', and the API adds (now - running_since)
-- on top of `elapsed_seconds` when reporting the live value — see src/routes/sessions.ts.
create table if not exists live_sessions (
  group_id text primary key,
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
