import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterEach, beforeEach } from 'vitest'
import { useApp } from '../src/store'

class MemoryStorage {
  private items = new Map<string, string>()
  get length() { return this.items.size }
  key(index: number) { return Array.from(this.items.keys())[index] ?? null }
  getItem(key: string) { return this.items.get(key) ?? null }
  setItem(key: string, value: string) { this.items.set(key, String(value)) }
  removeItem(key: string) { this.items.delete(key) }
  clear() { this.items.clear() }
}

if (!globalThis.localStorage) {
  Object.defineProperty(globalThis, 'localStorage', { value: new MemoryStorage(), configurable: true })
}

const initial = useApp.getState()

beforeEach(() => {
  localStorage.clear()
})

afterEach(() => {
  cleanup()
  useApp.getState().disconnect()
  useApp.setState(initial, true)
})
