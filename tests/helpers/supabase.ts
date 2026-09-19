import { beforeEach, vi } from 'vitest'
import { supabase } from '../../src/lib/supabaseClient.js'

vi.mock('../../src/lib/supabaseClient.js', () => ({
  supabase: { from: vi.fn(), rpc: vi.fn() },
}))

export const db = vi.mocked(supabase)

beforeEach(() => {
  vi.resetAllMocks()
})

// Only the Supabase boundary is mocked. Requests exercise the actual Express routers,
// Zod schemas and error middleware. Explicit query assertions protect scoping/projection.
export function queryResult(data: unknown, error: { message: string; code?: string } | null = null) {
  const result = { data, error }
  const query = {
    select: vi.fn().mockReturnThis(),
    order: vi.fn().mockReturnThis(),
    eq: vi.fn().mockReturnThis(),
    insert: vi.fn().mockReturnThis(),
    update: vi.fn().mockReturnThis(),
    delete: vi.fn().mockReturnThis(),
    upsert: vi.fn().mockReturnThis(),
    single: vi.fn().mockResolvedValue(result),
    maybeSingle: vi.fn().mockResolvedValue(result),
    then: (resolve: (value: typeof result) => unknown) => Promise.resolve(result).then(resolve),
  }
  db.from.mockReturnValueOnce(query as unknown as ReturnType<typeof supabase.from>)
  return query
}

export function rpcResult(data: unknown, error: { message: string; code?: string } | null = null) {
  db.rpc.mockResolvedValueOnce({ data, error } as Awaited<ReturnType<typeof supabase.rpc>>)
}
