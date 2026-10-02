// Structural view of EoP notifications; independent of the upstream checkout.
export interface TextNotification {
  target?: number
  text?: string
  media?: { url: string; caption?: string; kind?: string }[]
  fallback?: { text: string }
  setChatPhoto?: { url: string }
}

function decode(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (all, entity: string) => {
    const named: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' }
    if (!entity.startsWith('#')) return named[entity.toLowerCase()] ?? all
    const n = entity.charAt(1).toLowerCase() === 'x' ? parseInt(entity.slice(2), 16) : parseInt(entity.slice(1), 10)
    return n > 0 && n <= 0x10ffff && !(n >= 0xd800 && n <= 0xdfff) ? String.fromCodePoint(n) : all
  })
}

export function htmlToText(html: string): string {
  // Strip markup BEFORE decoding so literal user-authored <...> survives.
  return decode(html.replace(/<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/gi,
    (_, url: string, label: string) => `${label}（${url}）`)
    .replace(/<br\s*\/?\s*>/gi, '\n').replace(/<[^>]*>/g, '')).trim()
}

export function render(n: TextNotification): string {
  if (n.setChatPhoto) return ''
  if (n.media?.length) {
    return n.media.map(item => [htmlToText(item.caption ?? ''), item.url].filter(Boolean).join('\n')).join('\n\n')
  }
  return htmlToText(n.text ?? n.fallback?.text ?? '')
}

export function splitText(text: string, max = 1500): string[] {
  if (!Number.isInteger(max) || max < 1) throw new Error('invalid chunk size')
  const points = Array.from(text), out: string[] = []
  for (let i = 0; i < points.length; i += max) out.push(points.slice(i, i + max).join(''))
  return out
}
