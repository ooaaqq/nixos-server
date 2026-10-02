import { readFileSync } from 'node:fs'

export function biliupCookieHeader(raw: unknown): string {
  const entries = (raw as any)?.cookie_info?.cookies
  if (!Array.isArray(entries) || !entries.length) throw new Error('invalid biliup cookie document')
  const values = entries.map(item => {
    if (typeof item?.name !== 'string' || typeof item?.value !== 'string' || !/^[!#$%&'*+.^_`|~0-9a-z-]+$/i.test(item.name) || /[;\r\n]/.test(item.value))
      throw new Error('invalid biliup cookie entry')
    return `${item.name}=${item.value}`
  })
  return values.join('; ')
}

export function refreshBilibiliCookie(): void {
  const path = process.env.COOKIES_BILIBILI_FILE
  if (!path) return
  let header: string
  try { header = biliupCookieHeader(JSON.parse(readFileSync(path, 'utf8'))) }
  catch { throw new Error('cannot load COOKIES_BILIBILI_FILE as biliup JSON') }
  process.env.COOKIES_BILIBILI = header
}
