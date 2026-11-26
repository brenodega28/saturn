import { screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it } from 'vitest'
import { Connection } from '../src/connection'
import { Replica } from '../src/replica'
import { useApp } from '../src/store'
import type { FixtureServer } from './fixtureServer'
import { upsert } from './fixtureServer'
import { readSnapshot, renderApp, startFixture } from './helpers'

let server: FixtureServer | undefined

afterEach(async () => {
  await server?.stop()
  server = undefined
})

function message(id: number, text: string) {
  return upsert('leadMessage', id, { projectId: 1, taskId: 3, kind: 'lead', text, createdAt: '2026-11-25 15:00:00.000' })
}

describe('Connection', () => {
  it('sends hello with a persisted client ID and resumes from lastSeq after a drop', async () => {
    server = await startFixture()
    const replica = new Replica(readSnapshot)
    const statuses: string[] = []
    const connection = new Connection({ url: server.url(), token: server.validToken, replica, delays: [20], onStatus: (status) => statuses.push(status) })
    connection.start()
    await waitFor(() => expect(connection.status).toBe('online'))
    expect(server.hellos[0].lastSeq).toBeUndefined()
    const clientID = server.hellos[0].clientID
    expect(localStorage.getItem('saturn.clientID')).toBe(clientID)

    server.pushChanges([message(900, 'Before the drop')])
    await waitFor(() => expect(replica.seq).toBe(121))

    server.dropAll()
    server.pushChanges([message(901, 'While offline')], false)
    await waitFor(() => expect(statuses).toContain('offline'))

    await waitFor(() => expect(server!.hellos.length).toBe(2))
    expect(server.hellos[1]).toMatchObject({ clientID, lastSeq: 121, daemonID: '0F1C57A5-0000-4000-8000-000000000001' })
    await waitFor(() => expect(replica.row('leadMessage', 901)?.text).toBe('While offline'))
    expect(replica.seq).toBe(122)
    expect(replica.row('leadMessage', 900)?.text).toBe('Before the drop')
    await waitFor(() => expect(connection.status).toBe('online'))
    connection.stop()
  })

  it('takes a full snapshot again when the daemon says resync', async () => {
    server = await startFixture()
    const replica = new Replica(readSnapshot)
    const connection = new Connection({ url: server.url(), token: server.validToken, replica, delays: [20] })
    connection.start()
    await waitFor(() => expect(connection.status).toBe('online'))
    server.pushChanges([message(902, 'Old change')])
    await waitFor(() => expect(replica.seq).toBe(121))
    server.dropAll()
    server.oldestResumable = 500
    await waitFor(() => expect(server!.hellos.length).toBe(2))
    await waitFor(() => expect(connection.status).toBe('online'))
    expect(replica.row('task', 3)?.title).toBe('Hamburger menu for mobile')
    expect(replica.seq).toBe(121)
    connection.stop()
  })

  it('shows the offline banner while disconnected and hides it after reconnecting', async () => {
    server = await startFixture()
    await renderApp(server)
    expect(screen.queryByText(/Offline/)).not.toBeInTheDocument()
    server.dropAll()
    expect(await screen.findByText('Offline · reconnecting to Saturn')).toBeInTheDocument()
    await waitFor(() => expect(screen.queryByText(/Offline/)).not.toBeInTheDocument())
    expect(server.hellos.at(-1)?.lastSeq).toBe(120)
    expect(screen.getByRole('heading', { name: 'Hamburger menu for mobile' })).toBeInTheDocument()
  })

  it('goes back to pairing when the daemon closes with 4401', async () => {
    server = await startFixture()
    await renderApp(server)
    server.closeAll(4401)
    expect(await screen.findByRole('heading', { name: 'Pair with Saturn' })).toBeInTheDocument()
    expect(screen.getByText(/isn’t paired any more/)).toBeInTheDocument()
    expect(useApp.getState().token).toBeNull()
    expect(localStorage.getItem('saturn.remoteToken')).toBeNull()
  })

  it('rejects a wrong token with 4401 before any data', async () => {
    server = await startFixture()
    server.validToken = 'other'
    useApp.setState({ token: 'stale' })
    const { render } = await import('@testing-library/react')
    const { App } = await import('../src/App')
    render(<App socketURL={(token) => server!.url(token)} readSnapshot={readSnapshot} delays={[20]} />)
    expect(await screen.findByRole('heading', { name: 'Pair with Saturn' })).toBeInTheDocument()
    expect(server.tokens).toEqual(['stale'])
  })
})
