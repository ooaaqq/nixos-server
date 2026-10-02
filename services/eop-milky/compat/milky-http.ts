export class DeliveryError extends Error {}

export async function sendPrivate(baseUrl: string, token: string | undefined, userId: number, text: string, timeoutMs: number, signal?: AbortSignal): Promise<number> {
  let response: Response
  try {
    response = await fetch(`${baseUrl.replace(/\/+$/, '')}/api/send_private_message`, {
      method: 'POST', redirect: 'error',
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify({ user_id: userId, message: [{ type: 'text', data: { text } }] }),
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(timeoutMs)]) : AbortSignal.timeout(timeoutMs),
    })
  } catch { throw new DeliveryError('Milky network error or timeout') }
  if (!response.ok) throw new DeliveryError(`Milky HTTP ${response.status}`)
  let value: any
  try { value = await response.json() } catch { throw new DeliveryError('Milky invalid JSON') }
  if (value?.status !== 'ok' || value?.retcode !== 0 || !Number.isSafeInteger(value?.data?.message_seq) || value.data.message_seq < 0)
    throw new DeliveryError('Milky did not confirm successful delivery')
  return value.data.message_seq
}
