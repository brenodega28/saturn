import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import type { AddressInfo } from 'node:net'
import { WebSocketServer, type WebSocket } from 'ws'
import type { ChangeBatch, CommandEnvelope, CommandFailure, DBValue, Hello, RowChange } from '../src/protocol'

export type Answer = unknown | { error: CommandFailure }
export type CommandHandler = (args: any, server: FixtureServer) => Answer | Promise<Answer>

export interface ReceivedCommand {
  name: string
  args: any
}

export function readFixture(name: string): string[] {
  return readFileSync(resolve(__dirname, '../fixtures', name), 'utf8').split('\n').filter((line) => line.trim())
}

function kindOf(line: string): string {
  return Object.keys(JSON.parse(line))[0]
}

export function dbValue(value: unknown): DBValue {
  if (value === null || value === undefined) return null
  if (typeof value === 'boolean') return { i: value ? 1 : 0 }
  if (typeof value === 'number') return Number.isInteger(value) ? { i: value } : { r: value }
  return { t: String(value) }
}

export function upsert(table: string, rowID: number, row: Record<string, unknown>): Omit<RowChange, 'seq'> {
  const encoded: Record<string, DBValue> = {}
  for (const [key, value] of Object.entries({ id: rowID, ...row })) encoded[key] = dbValue(value)
  return { table, op: 'upsert', rowID, row: encoded }
}

export function remove(table: string, rowID: number): Omit<RowChange, 'seq'> {
  return { table, op: 'delete', rowID }
}

export class FixtureServer {
  readonly hellos: Hello[] = []
  readonly commands: ReceivedCommand[] = []
  readonly tokens: string[] = []
  validToken = 'test-token'
  handlers: Record<string, CommandHandler> = {}
  private server: WebSocketServer
  private clients = new Set<WebSocket>()
  private batches: ChangeBatch[] = []
  private snapshot: string[]
  private welcome: string
  private live: string
  seq: number
  oldestResumable = 0

  private constructor(lines: string[], server: WebSocketServer) {
    this.server = server
    this.welcome = lines.find((line) => kindOf(line) === 'welcome')!
    this.live = lines.find((line) => kindOf(line) === 'live')!
    this.snapshot = lines.filter((line) => kindOf(line).startsWith('snapshot'))
    const end = this.snapshot.find((line) => kindOf(line) === 'snapshotEnd')!
    this.seq = (JSON.parse(end).snapshotEnd._0 as { seq: number }).seq
    for (const line of lines.filter((candidate) => kindOf(candidate) === 'changes')) {
      const batch = JSON.parse(line).changes._0 as ChangeBatch
      this.batches.push(batch)
      this.seq = batch.seq
    }
    server.on('connection', (socket, request) => this.accept(socket, request.url ?? ''))
  }

  static start(lines: string[], handlers: Record<string, CommandHandler> = {}): Promise<FixtureServer> {
    return new Promise((done) => {
      const server = new WebSocketServer({ host: '127.0.0.1', port: 0, path: '/ws' })
      server.on('listening', () => {
        const fixture = new FixtureServer(lines, server)
        fixture.handlers = handlers
        done(fixture)
      })
    })
  }

  get port(): number {
    return (this.server.address() as AddressInfo).port
  }

  url(token = this.validToken): string {
    return `ws://127.0.0.1:${this.port}/ws?token=${encodeURIComponent(token)}`
  }

  get clientCount(): number {
    return this.clients.size
  }

  private accept(socket: WebSocket, url: string) {
    const token = new URL(url, 'http://localhost').searchParams.get('token') ?? ''
    this.tokens.push(token)
    if (token !== this.validToken) {
      socket.close(4401, 'unauthorized')
      return
    }
    this.clients.add(socket)
    socket.on('close', () => this.clients.delete(socket))
    socket.on('message', (data) => void this.receive(socket, data.toString()))
  }

  private async receive(socket: WebSocket, text: string) {
    const message = JSON.parse(text) as Record<string, { _0: any }>
    const kind = Object.keys(message)[0]
    if (kind === 'hello') return this.handshake(socket, message.hello._0 as Hello)
    if (kind === 'command') return this.command(socket, message.command._0 as CommandEnvelope)
    if (kind === 'file') return this.file(socket, message.file._0)
  }

  private handshake(socket: WebSocket, hello: Hello) {
    this.hellos.push(hello)
    socket.send(this.welcome)
    const daemonID = (JSON.parse(this.welcome).welcome._0 as { daemon: { id: string } }).daemon.id
    const lastSeq = hello.daemonID === daemonID ? hello.lastSeq : undefined
    if (lastSeq !== undefined && lastSeq >= this.oldestResumable - 1 && lastSeq <= this.seq) {
      for (const batch of this.batches) {
        const missing = batch.changes.filter((change) => change.seq > lastSeq)
        if (missing.length > 0) socket.send(JSON.stringify({ changes: { _0: { changes: missing, seq: batch.seq } } }))
      }
    } else {
      if (hello.lastSeq !== undefined) socket.send(JSON.stringify({ resync: { _0: { oldestSeq: this.oldestResumable } } }))
      for (const line of this.snapshot) socket.send(line)
      for (const batch of this.batches) socket.send(JSON.stringify({ changes: { _0: batch } }))
    }
    socket.send(this.live)
  }

  private async command(socket: WebSocket, envelope: CommandEnvelope) {
    const args = JSON.parse(Buffer.from(envelope.args, 'base64').toString('utf8'))
    this.commands.push({ name: envelope.name, args })
    const handler = this.handlers[envelope.name]
    const answer = handler ? await handler(args, this) : { error: { code: 'unknownCommand', message: `No fixture answer for ${envelope.name}` } }
    const result = answer && typeof answer === 'object' && 'error' in (answer as object)
      ? { id: envelope.id, error: (answer as { error: CommandFailure }).error }
      : { id: envelope.id, ok: Buffer.from(JSON.stringify(answer ?? {})).toString('base64') }
    socket.send(JSON.stringify({ result: { _0: result } }))
  }

  private file(socket: WebSocket, request: { requestID: string; id: string; kind: string }) {
    const text = request.kind === 'specDraft' ? '---\ntitle: Spec\n---\n## Summary\nA read-only spec.\n' : ''
    socket.send(JSON.stringify({ fileChunk: { _0: { requestID: request.requestID, offset: 0, data: Buffer.from(text).toString('base64'), end: false, caughtUp: false } } }))
    socket.send(JSON.stringify({ fileChunk: { _0: { requestID: request.requestID, offset: text.length, data: '', end: true, caughtUp: false } } }))
  }

  pushChanges(changes: Array<Omit<RowChange, 'seq'>>, send = true): ChangeBatch {
    const numbered = changes.map((change) => ({ ...change, seq: ++this.seq }))
    const batch = { changes: numbered, seq: this.seq }
    this.batches.push(batch)
    if (send) for (const client of this.clients) client.send(JSON.stringify({ changes: { _0: batch } }))
    return batch
  }

  pushLive(live: unknown) {
    this.live = JSON.stringify({ live: { _0: live } })
    for (const client of this.clients) client.send(this.live)
  }

  dropAll() {
    for (const client of this.clients) client.terminate()
    this.clients.clear()
  }

  closeAll(code: number) {
    for (const client of this.clients) client.close(code, 'closed by the fixture')
  }

  stop(): Promise<void> {
    this.dropAll()
    return new Promise((done) => this.server.close(() => done()))
  }
}
