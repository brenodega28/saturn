import type { CommandFailure, DaemonEvent, FileKind, LiveState, ResultEnvelope, Welcome } from './protocol'
import { decodeJSONData, decodeLive, decodeMessage, encodeJSONData, encodeMessage, fromBase64, newUUID, PROTOCOL_VERSION } from './protocol'
import type { Replica } from './replica'
import { readStored, writeStored } from './storage'

export type ConnectionStatus = 'connecting' | 'syncing' | 'online' | 'offline' | 'unauthorized' | 'refused'

export const UNAUTHORIZED_CLOSE = 4401
export const CLIENT_ID_KEY = 'saturn.clientID'
export const RECONNECT_DELAYS = [500, 1000, 2000, 4000, 8000, 15000]

export class CommandError extends Error {
  code: CommandFailure['code'] | 'offline'

  constructor(failure: { code: CommandFailure['code'] | 'offline'; message: string }) {
    super(failure.message)
    this.code = failure.code
  }
}

export interface ConnectionEvents {
  onStatus?: (status: ConnectionStatus, detail?: string) => void
  onReplica?: () => void
  onLive?: (live: LiveState) => void
  onWelcome?: (welcome: Welcome) => void
  onEvent?: (event: DaemonEvent) => void
}

export interface ConnectionOptions extends ConnectionEvents {
  url: string
  token: string
  replica: Replica
  socket?: (url: string) => WebSocket
  delays?: number[]
}

interface PendingFile {
  parts: Uint8Array[]
  resolve: (data: Uint8Array) => void
  reject: (error: Error) => void
}

export function socketURL(location: { protocol: string; host: string; pathname?: string }, token: string): string {
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:'
  return `${scheme}//${location.host}/ws?token=${encodeURIComponent(token)}`
}

export function clientID(): string {
  const stored = readStored(CLIENT_ID_KEY)
  if (stored) return stored
  const id = newUUID()
  writeStored(CLIENT_ID_KEY, id)
  return id
}

export class Connection {
  status: ConnectionStatus = 'connecting'
  daemonID: string | undefined
  private socket: WebSocket | null = null
  private attempt = 0
  private timer: ReturnType<typeof setTimeout> | null = null
  private stopped = false
  private queue: Promise<void> = Promise.resolve()
  private pending = new Map<string, { resolve: (value: unknown) => void; reject: (error: Error) => void }>()
  private files = new Map<string, PendingFile>()

  constructor(private options: ConnectionOptions) {}

  start(): void {
    this.stopped = false
    this.open()
  }

  stop(): void {
    this.stopped = true
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    const socket = this.socket
    this.socket = null
    if (socket && socket.readyState <= 1) {
      try {
        socket.send(encodeMessage('bye', undefined))
      } catch {
        // closing anyway
      }
      socket.close()
    }
    this.failPending('The connection closed.')
  }

  reconnectNow(): void {
    if (this.stopped || this.socket) return
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
    this.open()
  }

  send<T>(name: string, args: unknown): Promise<T> {
    const socket = this.socket
    if (!socket || socket.readyState !== 1 || this.status === 'connecting') {
      return Promise.reject(new CommandError({ code: 'offline', message: 'Saturn is offline. Try again when it reconnects.' }))
    }
    const id = newUUID()
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject })
      socket.send(encodeMessage('command', { id, name, args: encodeJSONData(args) }))
    })
  }

  readFile(kind: FileKind, id: string): Promise<Uint8Array> {
    const socket = this.socket
    if (!socket || socket.readyState !== 1) return Promise.reject(new Error('Saturn is offline.'))
    const requestID = newUUID()
    return new Promise((resolve, reject) => {
      this.files.set(requestID, { parts: [], resolve, reject })
      socket.send(encodeMessage('file', { requestID, kind, id, offset: 0, follow: false }))
    })
  }

  private setStatus(status: ConnectionStatus, detail?: string): void {
    this.status = status
    this.options.onStatus?.(status, detail)
  }

  private open(): void {
    if (this.options.replica.seq === null && this.status !== 'offline') this.setStatus('connecting')
    const factory = this.options.socket ?? ((url: string) => new WebSocket(url))
    let socket: WebSocket
    try {
      socket = factory(this.options.url)
    } catch {
      this.scheduleReconnect()
      return
    }
    this.socket = socket
    socket.onopen = () => this.sendHello(socket)
    socket.onmessage = (event) => {
      const text = typeof event.data === 'string' ? event.data : new TextDecoder().decode(event.data as ArrayBuffer)
      this.queue = this.queue.then(() => this.receive(text)).catch(() => socket.close())
    }
    socket.onclose = (event) => this.closed(socket, event.code)
    socket.onerror = () => undefined
  }

  private sendHello(socket: WebSocket): void {
    const seq = this.options.replica.seq
    socket.send(encodeMessage('hello', {
      clientID: clientID(),
      protocolVersion: PROTOCOL_VERSION,
      ...(this.daemonID ? { daemonID: this.daemonID } : {}),
      ...(seq !== null ? { lastSeq: seq } : {}),
    }))
  }

  private closed(socket: WebSocket, code: number): void {
    if (this.socket !== socket) return
    this.socket = null
    this.failPending('The connection dropped before Saturn answered.')
    if (this.stopped) return
    if (code === UNAUTHORIZED_CLOSE) {
      this.stopped = true
      this.setStatus('unauthorized')
      return
    }
    if (this.status === 'refused') return
    this.setStatus('offline')
    this.scheduleReconnect()
  }

  private scheduleReconnect(): void {
    if (this.stopped) return
    const delays = this.options.delays ?? RECONNECT_DELAYS
    const delay = delays[Math.min(this.attempt, delays.length - 1)]
    this.attempt++
    this.timer = setTimeout(() => {
      this.timer = null
      this.open()
    }, delay)
  }

  private failPending(message: string): void {
    for (const { reject } of this.pending.values()) reject(new CommandError({ code: 'offline', message }))
    this.pending.clear()
    for (const file of this.files.values()) file.reject(new Error(message))
    this.files.clear()
  }

  private async receive(text: string): Promise<void> {
    const message = decodeMessage(text)
    const replica = this.options.replica
    switch (message.kind) {
      case 'welcome':
        this.daemonID = message.value.daemon.id
        this.attempt = 0
        this.options.onWelcome?.(message.value)
        this.setStatus('syncing')
        break
      case 'refused':
        this.setStatus('refused', message.value.message)
        this.stopped = true
        this.socket?.close()
        break
      case 'resync':
        replica.resync()
        break
      case 'snapshotBegin':
        replica.beginSnapshot()
        break
      case 'snapshotChunk':
        replica.addChunk(message.value.data)
        break
      case 'snapshotEnd':
        await replica.endSnapshot(message.value.seq)
        this.options.onReplica?.()
        break
      case 'changes':
        replica.apply(message.value)
        this.options.onReplica?.()
        break
      case 'live':
        this.options.onLive?.(decodeLive(message.value))
        if (this.status !== 'online') this.setStatus('online')
        break
      case 'result':
        this.resolve(message.value)
        break
      case 'fileChunk': {
        const file = this.files.get(message.value.requestID)
        if (!file) break
        if (message.value.error) {
          this.files.delete(message.value.requestID)
          file.reject(new Error(message.value.error))
          break
        }
        if (message.value.data) file.parts.push(fromBase64(message.value.data))
        if (message.value.end) {
          this.files.delete(message.value.requestID)
          const size = file.parts.reduce((total, part) => total + part.length, 0)
          const data = new Uint8Array(size)
          let offset = 0
          for (const part of file.parts) {
            data.set(part, offset)
            offset += part.length
          }
          file.resolve(data)
        }
        break
      }
      case 'event':
        this.options.onEvent?.(message.value)
        break
      default:
        break
    }
  }

  private resolve(result: ResultEnvelope): void {
    const pending = this.pending.get(result.id)
    if (!pending) return
    this.pending.delete(result.id)
    if (result.error) {
      pending.reject(new CommandError(result.error))
      return
    }
    pending.resolve(result.ok ? decodeJSONData(result.ok) : undefined)
  }
}
