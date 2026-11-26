import { describe, expect, it } from 'vitest'
import { decodeMessage } from '../src/protocol'
import { Replica } from '../src/replica'
import { readFixture, remove, upsert } from './fixtureServer'
import { readSnapshot } from './helpers'

async function loadedReplica(): Promise<Replica> {
  const replica = new Replica(readSnapshot)
  for (const line of readFixture('mobile-v6.jsonl')) {
    const message = decodeMessage(line)
    if (message.kind === 'snapshotBegin') replica.beginSnapshot()
    if (message.kind === 'snapshotChunk') replica.addChunk(message.value.data)
    if (message.kind === 'snapshotEnd') await replica.endSnapshot(message.value.seq)
  }
  return replica
}

function batch(seq: number, changes: ReturnType<typeof upsert>[]) {
  return { seq: seq + changes.length, changes: changes.map((change, index) => ({ ...change, seq: seq + index + 1 })) }
}

describe('Replica', () => {
  it('builds its tables from the SQLite snapshot', async () => {
    const replica = await loadedReplica()
    expect(replica.isReady).toBe(true)
    expect(replica.seq).toBe(120)
    expect(replica.rows('project').map((row) => row.name)).toEqual(['monorepo', 'ensemble', 'perigee'])
    expect(replica.row('task', 3)?.title).toBe('Hamburger menu for mobile')
    expect(replica.row('run', 3)?.deliveryBranch).toBe('saturn/hamburger-menu')
    expect(replica.tables.has('changeLog')).toBe(false)
    expect(replica.tables.has('grdb_migrations')).toBe(false)
  })

  it('applies inserts, updates and deletes from a change batch', async () => {
    const replica = await loadedReplica()
    const before = replica.version
    replica.apply(batch(120, [
      upsert('leadMessage', 500, { projectId: 1, taskId: 3, kind: 'lead', text: 'Merged.', createdAt: '2026-11-25 15:00:00.000' }),
      upsert('task', 3, { projectId: 1, title: 'Hamburger menu', source: 'chat', status: 'done', createdAt: '2026-11-25 13:43:00.000', updatedAt: '2026-11-25 15:00:00.000' }),
      remove('leadMessage', 1),
    ]))
    expect(replica.seq).toBe(123)
    expect(replica.version).toBe(before + 1)
    expect(replica.row('leadMessage', 500)?.text).toBe('Merged.')
    expect(replica.row('task', 3)?.title).toBe('Hamburger menu')
    expect(replica.row('task', 3)?.status).toBe('done')
    expect(replica.row('leadMessage', 1)).toBeUndefined()
  })

  it('decodes every DBValue form', async () => {
    const replica = new Replica(readSnapshot)
    replica.applySnapshot(new Map(), 0)
    replica.apply({ seq: 1, changes: [{ seq: 1, table: 'evidence', op: 'upsert', rowID: 9, row: { id: { i: 9 }, note: { t: 'n' }, score: { r: 1.5 }, file: null, blob: { b: 'AQI=' } } }] })
    const row = replica.row('evidence', 9)!
    expect(row.id).toBe(9)
    expect(row.note).toBe('n')
    expect(row.score).toBe(1.5)
    expect(row.file).toBeNull()
    expect(Array.from(row.blob as Uint8Array)).toEqual([1, 2])
  })

  it('ignores unreplicated tables and replaces everything on resync', async () => {
    const replica = await loadedReplica()
    replica.apply({ seq: 121, changes: [{ seq: 121, table: 'changeLog', op: 'upsert', rowID: 1, row: { seq: { i: 1 } } }] })
    expect(replica.tables.has('changeLog')).toBe(false)
    replica.apply(batch(121, [upsert('task', 99, { projectId: 1, title: 'Gone after resync', source: 'chat', status: 'incoming' })]))
    replica.resync()
    expect(replica.seq).toBeNull()
    for (const line of readFixture('mobile-v6.jsonl')) {
      const message = decodeMessage(line)
      if (message.kind === 'snapshotBegin') replica.beginSnapshot()
      if (message.kind === 'snapshotChunk') replica.addChunk(message.value.data)
      if (message.kind === 'snapshotEnd') await replica.endSnapshot(message.value.seq)
    }
    expect(replica.row('task', 99)).toBeUndefined()
    expect(replica.seq).toBe(120)
  })
})
