# sports-training-api

Server-side API for the [sports-training-planner](https://github.com/BojanKocijan/basketball) frontend. Replaces the frontend's direct Supabase calls: the browser talks to this API, and this API is the only thing that talks to Supabase — using the `service_role` key, which never reaches the browser.

Owns the Supabase schema — see [`supabase/schema.sql`](supabase/schema.sql), run once in the Supabase SQL editor. The passcode check still happens via the `verify_passcode` Postgres function; this API just fronts it with a conventional REST surface instead of the frontend calling Supabase's client library and RPCs directly.

## Endpoints

| Method | Path | Auth |
|---|---|---|
| GET | `/health` | none |
| POST | `/auth/verify-passcode` | `passcode` in body |
| GET | `/clubs` | none |
| GET | `/clubs/:slug` | none |
| GET | `/plans?groupId=` | none |
| POST | `/plans` | `passcode` in body |
| PUT | `/plans/:id` | `passcode` in body |
| DELETE | `/plans/:id` | `passcode` in body |
| GET | `/sessions/:groupId` | none |
| POST | `/sessions/:groupId/start` | `passcode` in body |
| POST | `/sessions/:groupId/pause` | `passcode` in body |
| POST | `/sessions/:groupId/seek` | `passcode`, `seconds` in body |
| POST | `/sessions/:groupId/reset` | `passcode` in body |

`/sessions/:groupId` is the shared, live session clock for a group — every device polls `GET` to stay in sync, and the `start`/`pause`/`seek`/`reset` actions (passcode-gated, same as plans) let any unlocked trainer's phone control it for everyone.

## Setup

```bash
cp .env.example .env.local
# fill in SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ALLOWED_ORIGINS
npm install
npm run dev
```

**Requires Node 22+** (`@supabase/supabase-js`'s realtime client needs native `WebSocket`, which landed in Node 22). If `npm install` fails to resolve a native binding for `oxlint`/`vitest` on your platform (a known npm optional-dependency bug — [npm/cli#4828](https://github.com/npm/cli/issues/4828)), install the missing `@oxlint/binding-<platform>` / `@rolldown/binding-<platform>` package directly.

## Scripts

- `npm run dev` — dev server with reload
- `npm run test` / `npm run test:run` — Vitest
- `npm run build` — type-check + compile to `dist/`
- `npm run ci` — lint + test + build, same gate CI runs

## Deploying (Netlify Functions)

No separate host needed — this API ships as a Netlify Function, alongside (or on the same site as) the frontend, instead of a dedicated Railway/Render service.

`netlify/functions/api.ts` wraps the Express app from `src/app.ts` with [`serverless-http`](https://www.npmjs.com/package/serverless-http); `netlify.toml` redirects `/api/*` to it.

1. In Netlify → Site settings → Environment variables, set `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`, and `ALLOWED_ORIGINS`.
2. Deploy this repo as its own Netlify site, or add `netlify/functions/api.ts` + `netlify.toml` to the `sports-training-ui` repo so API and UI share one site (then `VITE_API_URL` can just be `/api`, same-origin, no CORS needed).
3. Verify with `<site-url>/api/health` → `{"status":"ok"}`.

Note: Netlify Functions are stateless/cold-start (no long-running process), which is fine for this app's request/response and short-poll traffic, but adds occasional cold-start latency versus an always-on host.
