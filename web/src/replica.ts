import type { ChangeBatch, DBValue, RowChange } from './protocol'
import { fromBase64 } from './protocol'

export type Value = null | number | string | Uint8Array
export type Row = Record<string, Value> & { rowid: number }
export type Table = Map<number, Row>
export type Tables = Map<string, Table>

export type SnapshotReader = (bytes: Uint8Array) => Promise<Tables>

export const UNREPLICATED_TABLES = new Set(['changeLog', 'grdb_migrations', 'sqlite_sequence'])

export function decodeValue(value: DBValue | undefined): Value {
  if (value === null || value === undefined) return null
  if ('i' in value) return value.i
  if ('r' in value) return value.r
  if ('t' in value) return value.t
  if ('b' in value) return fromBase64(value.b)
  return null
}

export function decodeRow(rowID: number, row: Record<string, DBValue>): Row {
  const decoded: Row = { rowid: rowID }
  for (const [column, value] of Object.entries(row)) decoded[column] = decodeValue(value)
  return decoded
}

export class Replica {
  tables: Tables = new Map()
  seq: number | null = null
  version = 0
  private chunks: Uint8Array[] = []
  private receiving = false

  constructor(private readSnapshot: SnapshotReader) {}

  get isReady(): boolean {
    return this.seq !== null && !this.receiving
  }

  table(name: string): Table {
    return this.tables.get(name) ?? new Map()
  }

  rows(name: string): Row[] {
    return Array.from(this.table(name).values())
  }

  row(name: string, rowID: number | null | undefined): Row | undefined {
    if (rowID === null || rowID === undefined) return undefined
    return this.tables.get(name)?.get(rowID)
  }

  beginSnapshot(): void {
    this.chunks = []
    this.receiving = true
  }

  addChunk(data: string): void {
    this.chunks.push(fromBase64(data))
  }

  async endSnapshot(seq: number): Promise<void> {
    const size = this.chunks.reduce((total, chunk) => total + chunk.length, 0)
    const bytes = new Uint8Array(size)
    let offset = 0
    for (const chunk of this.chunks) {
      bytes.set(chunk, offset)
      offset += chunk.length
    }
    this.chunks = []
    this.applySnapshot(await this.readSnapshot(bytes), seq)
  }

  applySnapshot(tables: Tables, seq: number): void {
    for (const name of UNREPLICATED_TABLES) tables.delete(name)
    this.tables = tables
    this.seq = seq
    this.receiving = false
    this.version++
  }

  resync(): void {
    this.seq = null
  }

  apply(batch: ChangeBatch): void {
    for (const change of batch.changes) this.applyChange(change)
    this.seq = batch.seq
    this.version++
  }

  private applyChange(change: RowChange): void {
    if (UNREPLICATED_TABLES.has(change.table)) return
    let table = this.tables.get(change.table)
    if (change.op === 'delete') {
      table?.delete(change.rowID)
      return
    }
    if (!change.row) return
    if (!table) {
      table = new Map()
      this.tables.set(change.table, table)
    }
    table.set(change.rowID, decodeRow(change.rowID, change.row))
  }
}
