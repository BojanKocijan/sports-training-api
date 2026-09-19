import request from 'supertest'
import { describe, expect, it } from 'vitest'
import { createApp } from './app.js'

describe('GET /health', () => {
  it('returns ok', async () => {
    const res = await request(createApp()).get('/health')
    expect(res.status).toBe(200)
    expect(res.body).toEqual({ status: 'ok' })
  })
})

describe('CORS', () => {
  it('rejects requests from an origin not in ALLOWED_ORIGINS', async () => {
    process.env.ALLOWED_ORIGINS = 'https://allowed.example.com'
    const res = await request(createApp())
      .get('/health')
      .set('Origin', 'https://evil.example.com')
    expect(res.headers['access-control-allow-origin']).toBeUndefined()
  })

  it('allows requests from an origin in ALLOWED_ORIGINS', async () => {
    process.env.ALLOWED_ORIGINS = 'https://allowed.example.com'
    const res = await request(createApp())
      .get('/health')
      .set('Origin', 'https://allowed.example.com')
    expect(res.headers['access-control-allow-origin']).toBe('https://allowed.example.com')
  })
})

describe('OpenAPI parent-code security contract', () => {
  it('documents body-only read credentials, no-store, and no legacy GET operation', async () => {
    const res = await request(createApp()).get('/openapi.json')
    const read = res.body.paths['/players/{id}/parent-code/read'].post

    expect(res.status).toBe(200)
    expect(read.requestBody.content['application/json'].schema).toBeDefined()
    expect(read.responses['200'].headers['Cache-Control'].schema).toMatchObject({
      type: 'string',
      enum: ['no-store'],
    })
    expect(res.body.paths['/players/{id}/parent-code'].get).toBeUndefined()
  })
})
