import { Database } from 'bun:sqlite'
import { chmodSync, existsSync } from 'node:fs'
import { randomUUID } from 'node:crypto'
import type { Config } from '@/types/config'
import type { RunContext } from '@/types/context'
import type { DbAccountScope } from '@/types/db'
import type { Service } from '@/types/service'
import { Store } from '@/utils/store'
import { openDb, persistScope } from '@/utils/db'
import { render, splitText } from './text'
import { sendPrivate } from './milky-http'
import { optionsFromEnv, type Options } from './options'
import { installFetchDeadline } from './fetch'
export { refreshBilibiliCookie } from './cookies'

interface Row { seq: number; recipient: number; text: string; attempts: number; due: number }
const TABLES = `
  CREATE TABLE IF NOT EXISTS milky_outbox (
    seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, account TEXT NOT NULL,
    service TEXT NOT NULL, recipient INTEGER NOT NULL, text TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0, due INTEGER NOT NULL DEFAULT 0,
    sent_at INTEGER, message_seq INTEGER);
  CREATE INDEX IF NOT EXISTS milky_pending ON milky_outbox(sent_at,seq);
  CREATE TABLE IF NOT EXISTS milky_baselines (
    account TEXT NOT NULL, service TEXT NOT NULL, identity TEXT NOT NULL,
    PRIMARY KEY(account,service));`

function copyInto(target: DbAccountScope, source: DbAccountScope) {
  for (const key of Object.keys(target)) delete target[key]
  Object.assign(target, source)
}

function sourceIdentity(ctx: RunContext, service: Service): string {
  const a = ctx.account
  const identity = service.name === 'bilibili-live' ? [a.biliId, a.biliLiveId]
    : service.name.startsWith('bilibili') ? a.biliId : a.weiboId
  // Changing the monitored UID requires a fresh baseline; the recipient is kept
  // separately, so changing the private QQ target does not replay old events.
  return JSON.stringify(identity ?? null)
}

function serviceKeys(name: string): string[] {
  if (name === 'bilibili-dynamics') return ['bilibili_mblog']
  if (name === 'bilibili-live') return ['bilibili_live']
  if (name === 'bilibili-following') return ['bilibili_following', 'bilibili_following_v1', 'bilibili_following_v2']
  return [name.replaceAll('-', '_')]
}

export class MilkyAdapter {
  readonly controller = new AbortController()
  private db?: Database
  private dispatcher?: Promise<void>
  private interrupted = false
  private failures = 0
  private requestTimeoutMs?: number
  private restoreFetch?: () => void
  private stopHandler = () => { this.interrupted = true; this.controller.abort() }
  constructor(readonly options: Options) {}
  get stopping() { return this.controller.signal.aborted }

  configure(config: Config) {
    const timeout = config.pluginOptions.requestTimeout ?? 10000
    if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 600000)
      throw new Error('pluginOptions.requestTimeout must be an integer between 1 and 600000')
    this.requestTimeoutMs = timeout
    const slugs = new Set<string>()
    for (const a of config.accounts) {
      if (!a.enabled) continue
      if (!a.slug || a.slug === '_global' || slugs.has(a.slug))
        throw new Error('Enabled accounts require unique nonempty slugs; _global is reserved')
      slugs.add(a.slug)
      if (a.rss?.length) throw new Error('Milky adapter does not cover the upstream inline RSS sender yet')
      if (a.douyinId || a.douyinLiveId || a.twitchId || a.tapechatId || a.afdianId || a.xiaohongshuId || a.enableSukiclub || a.twitterId || a.youtubeId || a.tiktokId)
        throw new Error('This adapter currently validates Bilibili and Weibo accounts only')
      if (a.bilibiliFetchCommentsWatchItems?.length || a.bilibiliFetchCommentsFromVupList)
        throw new Error('this EoP version does not implement explicit dynamic IDs or public VUP list import')
      a.tgChannelId = this.options.recipient
      a.tgChannelIdForComments = this.options.recipient
      a.tgChannelAvatarSource = []
    }
    config.telegram.enabled = false // prevent the remaining inline Telegram path
  }

  openDatabase(filename: string): Database {
    let db: Database
    if (this.options.mode === 'send') {
      db = openDb(filename)
      chmodSync(filename, 0o600)
    } else {
      db = openDb(':memory:')
      if (existsSync(filename)) {
        const original = new Database(filename, { readonly: true })
        try {
          original.transaction(() => db.transaction(() => {
            for (const row of original.query('SELECT * FROM entries').all() as { account_slug: string; service: string; data: string; updated_at: number }[])
              db.query('INSERT INTO entries VALUES(?,?,?,?)').run(row.account_slug, row.service, row.data, row.updated_at)
            db.exec(TABLES)
            for (const row of original.query('SELECT * FROM milky_baselines').all() as { account: string; service: string; identity: string }[])
              db.query('INSERT INTO milky_baselines VALUES(?,?,?)').run(row.account, row.service, row.identity)
          })())()
        } finally { original.close() }
      }
    }
    db.exec('PRAGMA synchronous=FULL;')
    db.exec(TABLES)
    this.db = db
    return db
  }

  async runService(ctx: RunContext, service: Service, db: Database, scope: DbAccountScope, global: DbAccountScope): Promise<void> {
    if (this.stopping) return
    const identity = sourceIdentity(ctx, service)
    const prior = db.query('SELECT identity FROM milky_baselines WHERE account=? AND service=?').get(ctx.account.slug, service.name) as { identity: string } | null
    const baseline = !prior || prior.identity !== identity
    const candidate = structuredClone(scope), candidateGlobal = structuredClone(global)
    if (prior && prior.identity !== identity) for (const key of serviceKeys(service.name)) delete candidate[key]
    const before = JSON.stringify(candidate)
    const oldStore = ctx.store, oldErr = ctx.err
    let failed = false
    ctx.store = new Store(candidate, candidateGlobal)
    ctx.err = () => { failed = true }
    try {
      const notifications = await service.run(ctx)
      if (failed) throw new Error('service reported a request failure')
      if (this.stopping) return
      if (!notifications.length && before === JSON.stringify(candidate) && JSON.stringify(global) === JSON.stringify(candidateGlobal)) return
      const messages: string[] = []
      for (const n of notifications) {
        const text = render(n)
        if (!baseline && text) messages.push(...splitText(text))
        n.onSent?.() // mutate only the isolated candidate, never the live scope
      }
      db.transaction(() => {
        for (const text of messages) db.query('INSERT INTO milky_outbox(id,account,service,recipient,text) VALUES(?,?,?,?,?)')
          .run(randomUUID(), ctx.account.slug, service.name, this.options.recipient, text)
        persistScope(db, ctx.account.slug, candidate)
        persistScope(db, '_global', candidateGlobal)
        db.query('INSERT INTO milky_baselines VALUES(?,?,?) ON CONFLICT(account,service) DO UPDATE SET identity=excluded.identity')
          .run(ctx.account.slug, service.name, identity)
      })()
      copyInto(scope, candidate); copyInto(global, candidateGlobal)
      if (baseline) ctx.log(`${service.name}: baseline established; no historical messages`)
      else if (messages.length) ctx.log(`${service.name}: queued ${messages.length} private messages`)
      if (this.options.mode === 'dry-run') for (const text of messages) console.log(`[preview]\n${text}`)
    } catch {
      this.failures++
      ctx.log(`${service.name}: failed; state unchanged, retry next poll`)
    } finally { ctx.store = oldStore; ctx.err = oldErr }
  }

  pending(): number {
    return (this.db!.query('SELECT count(*) AS n FROM milky_outbox WHERE sent_at IS NULL').get() as { n: number }).n
  }

  async drain(now?: number, signal?: AbortSignal): Promise<number> {
    if (this.options.mode !== 'send') return 0
    const clock = () => now ?? Date.now()
    let sent = 0
    while (sent < 20 && !signal?.aborted) {
      const row = this.db!.query('SELECT seq,recipient,text,attempts,due FROM milky_outbox WHERE sent_at IS NULL ORDER BY seq LIMIT 1').get() as Row | null
      if (!row || row.due > clock()) break
      let seq: number
      try {
        seq = await sendPrivate(this.options.baseUrl, this.options.token, row.recipient, row.text, this.options.timeoutMs, signal)
      } catch {
        if (signal?.aborted) break
        this.db!.query('UPDATE milky_outbox SET attempts=attempts+1,due=? WHERE seq=?')
          .run(clock() + Math.min(3600000, 5000 * 2 ** Math.min(row.attempts, 10)), row.seq)
        break
      }
      // A local SQL failure is fatal, rather than a network retry: an already
      // accepted QQ message must not be knowingly sent again in this process.
      this.db!.query('UPDATE milky_outbox SET sent_at=?,message_seq=? WHERE seq=?').run(Date.now(), seq, row.seq)
      sent++
    }
    return sent
  }

  start() {
    if (this.requestTimeoutMs !== undefined)
      this.restoreFetch = installFetchDeadline(this.controller.signal, this.requestTimeoutMs,
        `${this.options.baseUrl.replace(/\/+$/, '')}/api/send_private_message`)
    process.on('SIGINT', this.stopHandler); process.on('SIGTERM', this.stopHandler)
    if (this.options.mode === 'send' && !this.options.once) {
      this.dispatcher = (async () => {
        while (!this.stopping) {
          await this.drain(undefined, this.controller.signal)
          if (!this.stopping) await this.pause(1000)
        }
      })().catch(() => {
        this.failures++; this.controller.abort()
        console.error('Milky dispatcher failed; restart required')
        process.exitCode = 1
      })
    }
  }

  pause(ms: number): Promise<void> {
    return new Promise(resolve => {
      const done = () => { clearTimeout(timer); this.controller.signal.removeEventListener('abort', done); resolve() }
      const timer = setTimeout(done, ms)
      this.controller.signal.addEventListener('abort', done, { once: true })
      if (this.stopping) done()
    })
  }

  async finish() {
    try {
      if (this.dispatcher) this.controller.abort()
      await this.dispatcher
      if (this.options.once && !this.interrupted && this.options.mode === 'send')
        await this.drain(undefined, this.controller.signal)
      if (this.options.once && (this.failures || (this.options.mode === 'send' && this.pending()))) process.exitCode = 1
    } finally {
      this.controller.abort()
      this.restoreFetch?.()
      process.off('SIGINT', this.stopHandler); process.off('SIGTERM', this.stopHandler)
    }
  }
}

export function createMilkyAdapter(config: Config, once: boolean): MilkyAdapter {
  const adapter = new MilkyAdapter(optionsFromEnv(once))
  adapter.configure(config)
  return adapter
}
