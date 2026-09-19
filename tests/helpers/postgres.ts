import { execFileSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

// Integration tests require PostgreSQL server binaries (including pgcrypto), discoverable
// through pg_config, or TEST_POSTGRES_BIN=/path/to/postgres/bin. No npm dependencies,
// Docker, .env credentials or remote databases are used. Each run owns a fresh cluster.
export function createTestPostgres() {
  let root: string | undefined
  let bin: string
  let started = false

  function command(name: string, args: string[], input?: string) {
    return execFileSync(join(bin, name), args, {
      encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'], timeout: 30_000,
      env: { ...process.env, LC_ALL: 'C', PGOPTIONS: '' },
    }).trim()
  }

  function sql(statement: string) {
    if (!root || !started) throw new Error('Test PostgreSQL has not started')
    try {
      return command('psql', ['-X', '-qAt', '-v', 'ON_ERROR_STOP=1', '-h', root, '-p', '5432', '-U', 'postgres', '-d', 'postgres'], statement)
    } catch (error) {
      const stderr = (error as { stderr?: string }).stderr
      throw new Error(stderr || String(error))
    }
  }

  return {
    start() {
      try {
        bin = process.env.TEST_POSTGRES_BIN || execFileSync('pg_config', ['--bindir'], { encoding: 'utf8' }).trim()
        if (!existsSync(join(bin, 'initdb'))) throw new Error('initdb is missing')
      } catch {
        throw new Error('SQL MUST tests need local PostgreSQL with pgcrypto. Install PostgreSQL or set TEST_POSTGRES_BIN to its bin directory; no external database is contacted.')
      }
      // Short socket path avoids the Unix socket pathname limit on macOS.
      root = mkdtempSync(join(tmpdir(), 'api-pg-'))
      command('initdb', ['-D', join(root, 'data'), '-A', 'trust', '-U', 'postgres', '--no-locale', '--encoding=UTF8'])
      command('pg_ctl', ['-D', join(root, 'data'), '-l', join(root, 'server.log'), '-o', `-F -k ${root} -c listen_addresses='' -c unix_socket_permissions=0700`, '-w', 'start'])
      started = true
      sql('create role anon;')
      sql(readFileSync(resolve('supabase/schema.sql'), 'utf8'))
    },
    stop() {
      try {
        if (started && root) command('pg_ctl', ['-D', join(root, 'data'), '-m', 'immediate', '-w', 'stop'])
      } finally {
        started = false
        if (root) rmSync(root, { recursive: true, force: true })
      }
    },
    sql,
    rows(statement: string) {
      return JSON.parse(sql(`select coalesce(json_agg(result), '[]'::json) from (${statement}) result;`))
    },
  }
}
