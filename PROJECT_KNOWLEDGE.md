# Project Knowledge — sports-training-api

**Repo:** BojanKocijan/sports-training-api
**Owner:** @BojanKocijan
**Status:** active
**Pairs with:** [sports-training-ui](https://github.com/BojanKocijan/sports-training-ui) (local checkout: `basketball/`)

> Living memory for this project. Read at session start; updated whenever the project's purpose, architecture, or open questions change — not just at PR time.

---

## Milestone 1 — Business case

### What we're building

A pedagogy-and-development tool for volunteer youth-sports trainers — not a club administration platform. A trainer opens the app on the field, runs a structured, age-appropriate training session with a live-synced timer, and logs how each kid/group is developing. A parent, given a code by the trainer, sees their child's schedule and progress. That's the whole product. No membership admin, no payment collection, no chat — those are explicitly out of scope (see positioning below).

### Why this is worth the time (the market case)

Researched the Dutch amateur sports club market (Sept 2026):

- Nearly every major sport federation in NL (KNVB/football, KNHB/hockey, KNKV/korfbal, Nevobo/volleyball, NHV/handball, and now NBB/basketball via **Club.Basketball.nl**, launched June 2025) already gives clubs free, often near-mandatory software for **administration**: membership, attendance records, payments/invoicing, communication.
- That means competing on club administration is a losing bet — we'd be building a free alternative to something clubs already get free from their own federation.
- **But none of those platforms touch training content or pedagogy.** No exercise library, no session planning/running tool, no per-skill development tracking. That gap is real, structural, and not specific to basketball — it's true across every federation surveyed.
- Basketball specifically tends to be a single-sport club (not commonly combined with other sports in the Dutch "omnivereniging" model), so the near-term addressable shape is "one club, one sport" — with room to add a second sport per club later as a paid add-on (see monetization below), not a requirement to build multi-sport complexity now.

**The business case in one sentence:** federations already solve "who's coming and who's paid" for free — we solve "what do we actually do at training and is it working," which nobody else provides.

### Monetization (the actual license unit)

One subscription per **sport, per club** (`sport_subscriptions`, already in the schema). A club with just basketball pays for one; a club that later adds a second sport pays for a second. No payment processing needed yet — subscriptions are provisioned manually until there's real demand to automate it.

### Go-to-market

1. **Freemium/pilot for the trainer** — the trainer uses the basic version (session planning, live timer, progress tracking) for free, with no conversation with the club needed. That's the marketing.
   - **Trainer as informal referrer** — once a trainer sees the value (like Dunckers now), give them a simple one-line message/link they can forward to the treasurer/president: *"I'm using this — the club needs to pay €X/season to keep access for all groups and parents."* The trainer doesn't need to "sell," just pass along the decision.
   - **Club pays, becomes a reference** — every new paying club becomes proof for the next one (same school-by-school pattern Seesaw used).
2. **Federation (NBB/Club.Basketball.nl) comes later** — once there are 5–10 paying clubs as proof, approach as a partner with a track record, not as an unknown competitor to their admin tool.

### Proof this isn't just theory

The first real club (Dunckers Hilversum, U8 + U10 groups) is already using the shipped product with real data: logged plans, rated player progress, an active live session. This milestone is about deepening that, not starting from zero.

### What's in this milestone

Everything currently open in both repos, organized by the positioning above:

**Content & pedagogy (the actual product wedge)**
- Exercises/categories move from hardcoded frontend data into the database, scoped by sport — a new sport becomes data, not a code change.
- Pedagogical guidance shown live during a session, scoped by age group — not just what to do, but how to coach it at that age.
- Gamification of the existing progress data (per-category badges, "tried it all", group milestones, a season progress map, jersey unlocks) — confirmed ideas only, age-scoped, no leaderboards ranking kids against each other.

**Parent access (the lightweight, code-based layer)**
- A trainer issues a parent a code scoped to their child's nickname — no club-admin role, no email/password, no payment tracking.
- Parent view: child + group progress, training schedule, upcoming matches.
- One-way trainer notes on a training (e.g. "cancelled, rain") and parent-reported absences — explicitly not a messaging channel; that's WhatsApp's job, not ours.

**Competition**
- Matches/results tracked per group — same shape as training plans, no new access model needed.

**Multi-sport, gated by subscription**
- When a club has more than one sport, each sport is filtered by whether the club actually subscribed to it (`sports` → `groups` filter chain).

**Loose ends from earlier work**
- Session-control ownership indicator when two trainers are both unlocked at once (low priority — accepted tradeoff, pick up only if it's caused a real collision).
- Player promotion flow (reassigning a player to a new group next season).

### Explicitly not in this milestone

Club membership administration, payment collection/processing, in-app two-way messaging with parents. These lose to free federation tooling or already-dominant consumer tools (WhatsApp) — see positioning above. Not ruled out forever, just not where the time goes now.

---

## 1. What this project does and why

Backend API for a youth basketball club's training-session app. The club runs training for age-group squads (currently U8, expanding to more groups); each group has trainers who plan sessions, run a live shared timer during practice, track exercises the kids respond well to, and rate player progress per skill category. Parents get a read-only view of their own child via a trainer-issued code.

This API exists so the browser (`sports-training-ui`) never talks to Supabase directly. It owns the Supabase schema (`supabase/schema.sql`) and holds the `service_role` key — the frontend only ever calls this REST surface. Auth is a per-group trainer passcode (`verify_passcode` Postgres function), not user accounts: a code valid for one group doesn't unlock another.

**Current product direction (see open issues):** the team is actively deciding scope — whether this stays focused on training content/pedagogy (vs. club administration, which overlaps with existing federation platforms), and whether multi-sport support should be gated behind a per-sport subscription rather than built open-ended.

---

## 2. Target users

| Role | Description |
|---|---|
| Trainer | Plans sessions, runs the live group timer, rates exercises/players. Authenticates with a per-group passcode, not an account. |
| Parent | Read-only view of their own child's progress, via a trainer-issued single-child code. No write access. |
| Club admin (not yet built) | Would manage clubs/groups/rosters; currently seeded directly in Supabase. |

---

## 3. Architecture

| Layer | Choice | Why |
|---|---|---|
| Framework | Express 5, TypeScript, Zod for request validation | Small REST surface, easy to reason about |
| Data | Supabase (Postgres) via `@supabase/supabase-js`, `service_role` key | Frontend never sees Supabase credentials |
| Auth | Per-group passcode via `verify_passcode` Postgres function | No user accounts needed for a small club; passcode is scoped per group |
| Hosting | Netlify Functions (`netlify/functions/api.ts` wraps `src/app.ts` with `serverless-http`) | No dedicated server host needed; stateless, accepts cold-start latency in exchange |
| Testing | Vitest + Supertest | `npm run ci` = lint + test + build, same gate CI runs |

Routes live under `src/routes/` — one file per resource (`auth`, `categories`, `clubs`, `exercises`, `groups`, `plans`, `players`, `sessions`). `src/sessions.ts` route backs the shared live session clock: every trainer device polls `GET /sessions/:groupId`, and any unlocked trainer's `start`/`pause`/`seek`/`reset` action is visible to everyone in the group.

Players are a persistent identity, not locked to one group forever — `PUT /players/:id` can reassign `groupId` (e.g. promoted U8 → U10) while keeping nickname and full `player_progress_ratings` history. The passcode required is always the player's *current* group's.

---

## 4. Data layer

Real database: **Supabase (Postgres)**. Not mocks/localStorage — this is the persistence layer for the whole product; `sports-training-ui` uses `localStorage` only for device-local exercise ratings/history.

---

## 5. Open questions / product direction

- [ ] #23 — Positioning: is this training-content/pedagogy tool, or does it grow into club administration? Re-scope admin/payment work against overlap with federation platforms.
- [ ] #25 — Multi-sport UI exists but should be gated behind a per-sport subscription — the actual business model isn't decided yet.
- [ ] #18 — Parent portal data model: parent belongs to a group, child belongs to a parent (not yet built this way).
- [ ] #19 — Track matches/competitions and results per group (not yet modeled).
- [ ] #22 — Gamify progress tracking (badges/streaks/levels layered on the existing per-category ratings).
- [ ] #26 — Pedagogical guidance woven into a session, not just exercise steps.
- [ ] #27 — One-way trainer notes on a training + parent absence reporting.

---

## Changelog

- **2026-09-17** — #72 Mascot artwork resolves by sport + age range instead of inheriting through `group_templates`: new `mascot_stages` table (`baby`/`child`/`teen`/`adult` as real data with `min_age`/`max_age`, replacing a hardcoded CHECK on `mascot_avatars.stage`), and `groups`/`group_templates` both gained `sport_id`/`min_age`/`max_age` directly. Why: `groups.template_id` is `not null` today, so every group had to trace back to a fixed platform template to inherit sport/age — that breaks once clubs can rename groups or create custom ones with no template. Age numbers are placeholders (the mechanism matters, not the boundaries yet).
- **2026-09-17** — #43 Mascot avatars: added `mascots` (global animal roster, not sport-scoped — same identity follows a player across sports) + `mascot_avatars` (sport-scoped, life-stage-scoped artwork), `players.mascot_id`, and `group_templates.mascot_stage` (age band → baby/child/teen/adult, since players have no birthdate to derive it from). Roster seeded with just `lion` — more animals land as art is ready. New `GET /mascots` + `GET /mascots/avatars?sportId=&stage=`.
- **2026-09-16** — File created; captured current scope, architecture, and the open positioning questions (#18, #19, #22, #23, #25, #26, #27).
