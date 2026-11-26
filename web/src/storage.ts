export function readStored(key: string): string | null {
  try {
    return globalThis.localStorage?.getItem(key) ?? null
  } catch {
    return null
  }
}

export function writeStored(key: string, value: string | null): void {
  try {
    if (value === null) globalThis.localStorage?.removeItem(key)
    else globalThis.localStorage?.setItem(key, value)
  } catch {
    // storage can be blocked; the session still works in memory
  }
}

export const TOKEN_KEY = 'saturn.remoteToken'
export const DEVICE_KEY = 'saturn.remoteDevice'
