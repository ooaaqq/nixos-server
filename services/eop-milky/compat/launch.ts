import path from 'node:path'
import { mkdirSync, existsSync } from 'node:fs'
import { Database } from 'bun:sqlite'
import { optionsFromEnv } from './options'
import { MilkyAdapter } from './milky-adapter'
import { parseCLI } from './cli'
import { databasePath, lockPath } from './paths'

const args = process.argv.slice(2)
const cli = parseCLI(args)
process.env.EOP_MILKY_MODE = cli.mode

if (cli.help) {
  console.log('Usage: bun src/compat/launch.ts run [-c config.js] [--dry-run | --send] [--once]\n       --status (read-only queue counts)\n       --send --drain (send queued messages only)')
} else if (cli.status) {
  if (!existsSync(databasePath())) console.log(JSON.stringify({ pending: 0, retries: 0 }))
  else {
    const db = new Database(databasePath(), { readonly: true })
    try {
      const row = db.query('SELECT count(*) AS pending, coalesce(max(attempts),0) AS retries FROM milky_outbox WHERE sent_at IS NULL').get()
      console.log(JSON.stringify(row))
    } finally { db.close() }
  }
} else {
  const options = optionsFromEnv(cli.once)
  if (cli.mode === 'send' && process.env.EOP_MILKY_LOCK_HELD !== String(process.ppid)) {
    mkdirSync('db', { recursive: true, mode: 0o700 })
    const child = Bun.spawn(['flock', '--nonblock', '--no-fork', lockPath(), process.execPath,
      ...process.execArgv, import.meta.filename, ...args], {
      env: { ...process.env, EOP_MILKY_LOCK_HELD: String(process.pid) },
      stdin: 'inherit', stdout: 'inherit', stderr: 'inherit',
    })
    const stop = () => child.kill('SIGTERM')
    process.on('SIGINT', stop); process.on('SIGTERM', stop)
    try { process.exitCode = await child.exited }
    finally { process.off('SIGINT', stop); process.off('SIGTERM', stop) }
  } else if (cli.drain) {
    const adapter = new MilkyAdapter(options)
    const db = adapter.openDatabase(databasePath())
    try { adapter.start(); await adapter.finish(); console.log(`pending=${adapter.pending()}`) }
    finally { db.close() }
  } else {
    const entrypoint = path.resolve(import.meta.dir, '../index.ts')
    process.argv = [process.execPath, entrypoint, ...cli.upstreamArgs]
    await import(entrypoint)
  }
}
