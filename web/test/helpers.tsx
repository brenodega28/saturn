import { readFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { render, screen, waitFor } from '@testing-library/react'
import { expect } from 'vitest'
import { App } from '../src/App'
import { sqliteSnapshotReader } from '../src/sqlite'
import { useApp } from '../src/store'
import type { CommandHandler } from './fixtureServer'
import { FixtureServer, readFixture } from './fixtureServer'

const require = createRequire(import.meta.url)
const wasmBinary = readFileSync(require.resolve('sql.js/dist/sql-wasm.wasm'))

export const readSnapshot = sqliteSnapshotReader({ wasmBinary: wasmBinary.buffer.slice(wasmBinary.byteOffset, wasmBinary.byteOffset + wasmBinary.byteLength) as ArrayBuffer })

export const DIFF = { paths: ['src/Hamburger.tsx', 'src/MobileMenu.tsx', 'src/nav.module.css', 'src/nav.spec.ts', 'src/App.tsx', 'src/index.css', 'e2e/menu.spec.ts'], added: 186, deleted: 24 }

export const defaultHandlers: Record<string, CommandHandler> = {
  'chat.markViewed': () => ({}),
  'run.diffSummary': () => DIFF,
}

export async function startFixture(handlers: Record<string, CommandHandler> = {}) {
  return FixtureServer.start(readFixture('mobile-v6.jsonl'), { ...defaultHandlers, ...handlers })
}

export async function renderApp(server: FixtureServer, chatID: number | null = 3) {
  useApp.setState({ token: server.validToken, chatID })
  const view = render(<App socketURL={(token) => server.url(token)} readSnapshot={readSnapshot} delays={[30, 60]} />)
  await waitFor(() => expect(useApp.getState().status).toBe('online'))
  await screen.findByRole('main', { name: 'Chat' })
  return view
}
