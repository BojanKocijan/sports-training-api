import cors from 'cors'
import express from 'express'
import { errorHandler } from './middleware/errorHandler.js'
import { authRouter } from './routes/auth.js'
import { clubsRouter } from './routes/clubs.js'
import { plansRouter } from './routes/plans.js'
import { sessionsRouter } from './routes/sessions.js'

export function createApp() {
  const app = express()
  const allowedOrigins = (process.env.ALLOWED_ORIGINS ?? '')
    .split(',')
    .map((o) => o.trim())
    .filter(Boolean)

  app.use(
    cors({
      origin: allowedOrigins.length > 0 ? allowedOrigins : false,
    }),
  )
  app.use(express.json())

  app.get('/health', (_req, res) => res.json({ status: 'ok' }))
  app.use('/auth', authRouter)
  app.use('/clubs', clubsRouter)
  app.use('/plans', plansRouter)
  app.use('/sessions', sessionsRouter)

  app.use(errorHandler)

  return app
}
