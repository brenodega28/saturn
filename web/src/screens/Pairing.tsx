import { useEffect, useRef, useState } from 'react'
import { DEVICE_KEY, writeStored } from '../storage'

export function pairingCode(hash: string): string {
  const match = /^#pair(?:[=/:]|\?code=)?(\d{6})?/.exec(hash)
  return match?.[1] ?? ''
}

export async function pair(code: string, fetcher: typeof fetch = fetch): Promise<{ token: string; deviceID?: string }> {
  const response = await fetcher('pair', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ code }),
  })
  if (response.status === 401) throw new Error('That code didn’t work. It works once and expires after 5 minutes. Make a new one on the Mac.')
  if (!response.ok) throw new Error(`Saturn couldn’t pair this device (HTTP ${response.status}).`)
  return (await response.json()) as { token: string; deviceID?: string }
}

export function Pairing({ onPaired, reason }: { onPaired: (token: string) => void; reason?: string }) {
  const [code, setCode] = useState(() => pairingCode(window.location.hash))
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const autoSubmitted = useRef(false)

  const submit = async (value: string) => {
    if (!/^\d{6}$/.test(value)) {
      setError('Enter the 6-digit code shown on the Mac.')
      return
    }
    setBusy(true)
    setError(null)
    try {
      const result = await pair(value)
      if (result.deviceID) writeStored(DEVICE_KEY, result.deviceID)
      if (window.location.hash.startsWith('#pair')) history.replaceState(null, '', window.location.pathname + window.location.search)
      onPaired(result.token)
    } catch (failure) {
      setError(failure instanceof TypeError ? 'Couldn’t reach Saturn. Check that Remote access is on and this device is on the same network or Tailscale.' : (failure as Error).message)
    } finally {
      setBusy(false)
    }
  }

  useEffect(() => {
    if (!autoSubmitted.current && /^\d{6}$/.test(code)) {
      autoSubmitted.current = true
      void submit(code)
    }
  }, [])

  return (
    <main className="pairing">
      <form onSubmit={(event) => { event.preventDefault(); void submit(code) }}>
        <h1>Pair with Saturn</h1>
        <p>{reason ?? 'On your Mac, open Saturn › Settings › Remote access and choose Pair a device. Then enter the code it shows.'}</p>
        <label>
          Pairing code
          <input inputMode="numeric" autoComplete="one-time-code" pattern="\d{6}" maxLength={6} placeholder="000000" value={code}
            onChange={(event) => setCode(event.target.value.replace(/\D/g, '').slice(0, 6))} aria-describedby={error ? 'pair-error' : undefined} />
        </label>
        {error && <span id="pair-error" className="error" role="alert">{error}</span>}
        <button type="submit" className="button primary" disabled={busy || code.length !== 6}>{busy ? 'Pairing…' : 'Pair this device'}</button>
      </form>
    </main>
  )
}
