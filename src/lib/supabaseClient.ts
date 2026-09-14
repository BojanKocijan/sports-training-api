import { createClient } from '@supabase/supabase-js'

const url = process.env.SUPABASE_URL
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY

if (!url || !serviceRoleKey) {
  throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY must be set (see .env.example)')
}

// service_role bypasses Row Level Security entirely — this client has full table access.
// That's intentional: it's only ever used server-side, and the passcode check in the
// plans routes (via the verify_passcode RPC) is what actually gates writes, not RLS.
export const supabase = createClient(url, serviceRoleKey, {
  auth: { persistSession: false },
})
