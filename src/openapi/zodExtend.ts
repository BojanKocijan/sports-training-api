import { extendZodWithOpenApi } from '@asteasolutions/zod-to-openapi'
import { z } from 'zod'

// Side-effect only -- adds `.openapi(...)` to every zod schema. Must be imported before any
// module calls `.openapi()`, which is why document.ts imports this first, above every route's
// schema imports.
extendZodWithOpenApi(z)
