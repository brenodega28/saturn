export const PROTOCOL_VERSION = 1

export type UUID = string
export type Base64 = string
export type ISODate = string

export type DBValue = null | { i: number } | { r: number } | { t: string } | { b: Base64 }

export type ChangeOperation = 'upsert' | 'delete'

export interface RowChange {
  seq: number
  table: string
  op: ChangeOperation
  rowID: number
  row?: Record<string, DBValue>
}

export interface DaemonIdentity {
  id: UUID
  name: string
  protocolVersion: number
}

export interface Hello {
  clientID: UUID
  protocolVersion: number
  daemonID?: UUID
  lastSeq?: number
}

export interface Welcome {
  daemon: DaemonIdentity
  protocolVersion: number
  buildVersion: string
}

export type RefusalCode = 'daemonTooOld' | 'clientTooOld' | 'badRequest'

export interface Refusal {
  code: RefusalCode
  message: string
  daemonProtocolVersion: number
}

export type FileKind = 'transcript' | 'evidence' | 'specDraft' | 'attachment' | 'agentFile'

export interface FileRequest {
  requestID: UUID
  kind: FileKind
  id: string
  offset: number
  follow: boolean
}

export interface FileChunk {
  requestID: UUID
  offset: number
  data: Base64
  end: boolean
  error?: string
  caughtUp: boolean
}

export interface CommandEnvelope {
  id: UUID
  name: string
  args: Base64
}

export type CommandErrorCode = 'alreadyAnswered' | 'notFound' | 'unknownCommand' | 'invalidArguments' | 'failed' | 'forbidden'

export interface CommandFailure {
  code: CommandErrorCode
  message: string
}

export interface ResultEnvelope {
  id: UUID
  ok?: Base64
  error?: CommandFailure
}

export interface SnapshotHeader {
  seq: number
  size: number
}

export interface SnapshotChunk {
  data: Base64
}

export interface ResyncNotice {
  oldestSeq: number
}

export interface ChangeBatch {
  changes: RowChange[]
  seq: number
}

export interface LiveRetry {
  attempt: number
  maxRetries: number
  delayMS: number
  status?: number
  error?: string
}

export interface LiveAgent {
  isRunning: boolean
  isStopping: boolean
  isQueued: boolean
  canResume: boolean
  isSettingUp: boolean
  setupFailed: boolean
  isUpdatingMemory: boolean
  queuedMessages: string[]
  lastOutputAt?: ISODate
  retryingAt?: ISODate
  apiRetry?: LiveRetry
}

export interface DaemonEnvironment {
  hostName: string
  homeDirectory: string
  providerReady: boolean
  [key: string]: unknown
}

export interface LiveStateWire {
  agents: Record<string, LiveAgent> | Array<number | LiveAgent>
  drivingRunIDs: number[]
  waitingForCapacity: number[]
  apiCooldownUntil?: ISODate
  usageRevision: number
  environment: DaemonEnvironment
  mcpReady: boolean
  startedAt: ISODate
}

export interface LiveState {
  agents: Map<number, LiveAgent>
  drivingRunIDs: Set<number>
  waitingForCapacity: Set<number>
  usageRevision: number
  hostName: string
}

export type DaemonEvent =
  | { leadTurnEnded: { taskId: number } }
  | { worktreeRemoving: { path: string } }
  | { agentReplied: { agentId: number } }
  | { specDrafted: { projectId: number; taskId: number; path: string } }
  | { specReviewEnded: { taskId: number } }
  | { readChat: Record<string, unknown> }
  | { shuttingDown: Record<string, never> }

type Payload<T> = { _0: T }

export type ProtocolMessage =
  | { event: Payload<DaemonEvent> }
  | { hello: Payload<Hello> }
  | { welcome: Payload<Welcome> }
  | { refused: Payload<Refusal> }
  | { resync: Payload<ResyncNotice> }
  | { snapshotBegin: Payload<SnapshotHeader> }
  | { snapshotChunk: Payload<SnapshotChunk> }
  | { snapshotEnd: Payload<SnapshotHeader> }
  | { changes: Payload<ChangeBatch> }
  | { live: Payload<LiveStateWire> }
  | { command: Payload<CommandEnvelope> }
  | { result: Payload<ResultEnvelope> }
  | { file: Payload<FileRequest> }
  | { fileCancel: Payload<FileRequest> }
  | { fileChunk: Payload<FileChunk> }
  | { bye: Record<string, never> }

export type MessageKind = 'event' | 'hello' | 'welcome' | 'refused' | 'resync' | 'snapshotBegin' | 'snapshotChunk'
  | 'snapshotEnd' | 'changes' | 'live' | 'command' | 'result' | 'file' | 'fileCancel' | 'fileChunk' | 'bye'

export interface MessagePayloads {
  event: DaemonEvent
  hello: Hello
  welcome: Welcome
  refused: Refusal
  resync: ResyncNotice
  snapshotBegin: SnapshotHeader
  snapshotChunk: SnapshotChunk
  snapshotEnd: SnapshotHeader
  changes: ChangeBatch
  live: LiveStateWire
  command: CommandEnvelope
  result: ResultEnvelope
  file: FileRequest
  fileCancel: FileRequest
  fileChunk: FileChunk
  bye: undefined
}

export type Decoded = { [K in MessageKind]: { kind: K; value: MessagePayloads[K] } }[MessageKind]

export function encodeMessage<K extends MessageKind>(kind: K, value: MessagePayloads[K]): string {
  if (kind === 'bye') return JSON.stringify({ bye: {} })
  return JSON.stringify({ [kind]: { _0: value } })
}

export function decodeMessage(text: string): Decoded {
  const object = JSON.parse(text) as Record<string, { _0?: unknown }>
  const kind = Object.keys(object)[0] as MessageKind
  if (!kind) throw new Error('Empty protocol message')
  const value = kind === 'bye' ? undefined : object[kind]?._0
  return { kind, value } as Decoded
}

export function decodeLive(wire: LiveStateWire): LiveState {
  const agents = new Map<number, LiveAgent>()
  if (Array.isArray(wire.agents)) {
    for (let index = 0; index + 1 < wire.agents.length; index += 2) {
      agents.set(Number(wire.agents[index]), wire.agents[index + 1] as LiveAgent)
    }
  } else {
    for (const [key, agent] of Object.entries(wire.agents ?? {})) agents.set(Number(key), agent)
  }
  return {
    agents,
    drivingRunIDs: new Set(wire.drivingRunIDs ?? []),
    waitingForCapacity: new Set(wire.waitingForCapacity ?? []),
    usageRevision: wire.usageRevision ?? 0,
    hostName: wire.environment?.hostName ?? '',
  }
}

export function emptyLive(): LiveState {
  return { agents: new Map(), drivingRunIDs: new Set(), waitingForCapacity: new Set(), usageRevision: 0, hostName: '' }
}

export function toBase64(bytes: Uint8Array): string {
  let binary = ''
  const step = 0x8000
  for (let index = 0; index < bytes.length; index += step) {
    binary += String.fromCharCode(...bytes.subarray(index, index + step))
  }
  return btoa(binary)
}

export function fromBase64(text: string): Uint8Array {
  const binary = atob(text)
  const bytes = new Uint8Array(binary.length)
  for (let index = 0; index < binary.length; index++) bytes[index] = binary.charCodeAt(index)
  return bytes
}

export function encodeJSONData(value: unknown): Base64 {
  return toBase64(new TextEncoder().encode(JSON.stringify(value)))
}

export function decodeJSONData<T>(data: Base64): T {
  return JSON.parse(new TextDecoder().decode(fromBase64(data))) as T
}

export function newUUID(): UUID {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID().toUpperCase()
  const bytes = new Uint8Array(16)
  crypto.getRandomValues(bytes)
  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80
  const hex = Array.from(bytes, (byte) => byte.toString(16).padStart(2, '0')).join('')
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`.toUpperCase()
}
