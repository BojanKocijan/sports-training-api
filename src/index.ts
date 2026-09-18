import './env.js'
import { createApp } from './app.js'

const port = Number(process.env.PORT ?? 3001)
const app = createApp()

app.listen(port, () => {
  console.log(`sports-training-api listening on :${port}`)
})
