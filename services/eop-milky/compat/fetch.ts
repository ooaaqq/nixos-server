/** Bound upstream requests without maintaining forks of platform modules. */
export function installFetchDeadline(signal: AbortSignal, timeoutMs: number, excludeUrl?: string): () => void {
  const original = globalThis.fetch
  const wrapped = (async (input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) => {
    const url = input instanceof Request ? input.url : String(input)
    if (url === excludeUrl) return original(input, init) // Milky has its own timeout and shutdown signal.
    const callerSignal = init?.signal ?? (input instanceof Request ? input.signal : undefined)
    const signals = [signal, AbortSignal.timeout(timeoutMs)]
    if (callerSignal) signals.push(callerSignal)
    return original(input, { ...init, signal: AbortSignal.any(signals) })
  }) as typeof fetch
  wrapped.preconnect = original.preconnect
  globalThis.fetch = wrapped
  return () => { if (globalThis.fetch === wrapped) globalThis.fetch = original }
}
