export interface Options {
  mode: 'send' | 'dry-run'
  recipient: number
  baseUrl: string
  token?: string
  timeoutMs: number
  once: boolean
}

export function optionsFromEnv(once = false): Options {
  const mode = process.env.EOP_MILKY_MODE ?? 'dry-run'
  if (mode !== 'send' && mode !== 'dry-run') throw new Error('EOP_MILKY_MODE must be send or dry-run')
  const integer = (name: string, fallback?: number) => {
    const raw = process.env[name] ?? String(fallback ?? '')
    const value = Number(raw)
    if (!/^\d+$/.test(raw) || !Number.isSafeInteger(value) || value < 1) throw new Error(`invalid ${name}`)
    return value
  }
  const recipient = integer('EOP_QQ_RECIPIENT')
  let url: URL
  try { url = new URL(process.env.EOP_MILKY_BASE_URL ?? 'http://127.0.0.1:3010') }
  catch { throw new Error('invalid EOP_MILKY_BASE_URL') }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash)
    throw new Error('EOP_MILKY_BASE_URL must be HTTP(S) without URL credentials')
  const timeoutMs = integer('EOP_MILKY_TIMEOUT_MS', 10000)
  if (timeoutMs > 600000) throw new Error('EOP_MILKY_TIMEOUT_MS must be <= 600000')
  return { mode, recipient, baseUrl: url.toString().replace(/\/+$/, ''),
    token: process.env.MILKY_ACCESS_TOKEN || undefined, timeoutMs, once }
}
