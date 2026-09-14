import 'dotenv/config'
import serverless from 'serverless-http'
import { createApp } from '../../src/app.js'

export const handler = serverless(createApp())
