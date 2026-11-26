import initSqlJs from 'sql.js'
import type { SqlJsConfig, SqlJsStatic } from 'sql.js'
import type { Row, SnapshotReader, Table, Tables, Value } from './replica'
import { UNREPLICATED_TABLES } from './replica'

let engine: Promise<SqlJsStatic> | null = null

export function loadEngine(config?: SqlJsConfig): Promise<SqlJsStatic> {
  engine ??= initSqlJs(config)
  return engine
}

function quoted(name: string): string {
  return `"${name.replaceAll('"', '""')}"`
}

export function sqliteSnapshotReader(config?: SqlJsConfig): SnapshotReader {
  return async (bytes) => {
    const SQL = await loadEngine(config)
    const db = new SQL.Database(bytes)
    try {
      const tables: Tables = new Map()
      const names = db.exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")[0]?.values ?? []
      for (const [name] of names) {
        const tableName = String(name)
        if (UNREPLICATED_TABLES.has(tableName)) continue
        const table: Table = new Map()
        const statement = db.prepare(`SELECT rowid AS "__rowid__", * FROM ${quoted(tableName)}`)
        while (statement.step()) {
          const values = statement.getAsObject() as Record<string, Value>
          const rowid = Number(values.__rowid__)
          delete values.__rowid__
          table.set(rowid, { ...values, rowid } as Row)
        }
        statement.free()
        tables.set(tableName, table)
      }
      return tables
    } finally {
      db.close()
    }
  }
}
