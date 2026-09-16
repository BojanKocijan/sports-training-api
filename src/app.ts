import cors from 'cors'
import express from 'express'
import { errorHandler } from './middleware/errorHandler.js'
import { authRouter } from './routes/auth.js'
import { categoriesRouter } from './routes/categories.js'
import { clubsRouter } from './routes/clubs.js'
import { exercisesRouter } from './routes/exercises.js'
import { groupsRouter } from './routes/groups.js'
import { plansRouter } from './routes/plans.js'
import { playersRouter } from './routes/players.js'
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

  app.get('/', (_req, res) =>
    res.json({ service: 'sports-training-api', docs: 'https://github.com/BojanKocijan/sports-training-api' }),
  )
  app.get('/health', (_req, res) => res.json({ status: 'ok' }))
  app.use('/auth', authRouter)
  app.use('/clubs', clubsRouter)
  app.use('/exercises', exercisesRouter)
  app.use('/categories', categoriesRouter)
  app.use('/groups', groupsRouter)
  app.use('/plans', plansRouter)
  app.use('/players', playersRouter)
  app.use('/sessions', sessionsRouter)

  app.use(errorHandler)

  return app
}
