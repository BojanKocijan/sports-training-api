import dotenv from 'dotenv'

// Bare 'dotenv/config' only auto-loads a file literally named .env, never .env.local — but
// the README (and .gitignore, which excludes .env.local from version control) both assume
// .env.local is where real local credentials live. Must be imported before anything that
// reads process.env at module-evaluation time (e.g. supabaseClient.ts) — a plain
// `dotenv.config()` statement inside index.ts's own body runs too late for that, since all of
// a module's imports are evaluated before its own top-level statements. Putting the call in
// this module's own top level, and importing this module first, keeps the ordering correct.
dotenv.config({ path: ['.env.local', '.env'] })
