# sports-training-api

Server-side API for the [sports-training-planner](https://github.com/BojanKocijan/basketball) frontend. Replaces the frontend's direct Supabase calls: the browser talks to this API, and this API is the only thing that talks to Supabase — using the `service_role` key, which never reaches the browser.

Same Supabase project/schema as the frontend (see `basketball/supabase/schema.sql`) — no database migration needed. The passcode check still happens via the existing `verify_passcode` Postgres function; this API just fronts it with a conventional REST surface instead of the frontend calling Supabase's client library and RPCs directly.

## Endpoints

| Method | Path | Auth |
|---|---|---|
| GET | `/health` | none |
| GET | `/clubs` | none |
| GET | `/clubs/:slug` | none |
| GET | `/plans?groupId=` | none |
| POST | `/plans` | `passcode` in body |
| PUT | `/plans/:id` | `passcode` in body |
| DELETE | `/plans/:id` | `passcode` in body |

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
