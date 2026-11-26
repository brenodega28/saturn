import { create } from 'zustand'
import type { ChatGroup, ChatSummary } from './chats'
import { chatSummaries, filterChats, groupChats } from './chats'
import type { Commands, DiffInfo } from './commands'
import { commands } from './commands'
import type { ConnectionStatus } from './connection'
import { Connection } from './connection'
import type { LiveState } from './protocol'
import { emptyLive } from './protocol'
import type { Records } from './records'
import { readRecords } from './records'
import type { SnapshotReader } from './replica'
import { Replica } from './replica'
import { TOKEN_KEY, readStored, writeStored } from './storage'

export type Drawer = 'none' | 'left' | 'right'
export type DetailsTab = 'task' | 'project' | 'log'

export interface Session {
  connection: Connection
  replica: Replica
  commands: Commands
}

export interface SessionOptions {
  url: string
  token: string
  readSnapshot: SnapshotReader
  socket?: (url: string) => WebSocket
  delays?: number[]
}

export type DiffState = { status: 'loading' } | { status: 'ready'; diff: DiffInfo } | { status: 'error'; message: string }

export interface AppState {
  token: string | null
  status: ConnectionStatus
  statusDetail?: string
  everOnline: boolean
  version: number
  live: LiveState
  daemonName: string
  chatID: number | null
  drawer: Drawer
  detailsTab: DetailsTab
  projectFilter: number | null
  search: string
  reviewing: boolean
  composing: boolean
  diffs: Record<number, DiffState>
  notice: string | null
  session: Session | null

  setToken: (token: string | null) => void
  connect: (options: SessionOptions) => void
  disconnect: () => void
  openChat: (chatID: number) => void
  setDrawer: (drawer: Drawer) => void
  setDetailsTab: (tab: DetailsTab) => void
  setProjectFilter: (projectID: number | null) => void
  setSearch: (search: string) => void
  setReviewing: (reviewing: boolean) => void
  setComposing: (composing: boolean) => void
  loadDiff: (runID: number, force?: boolean) => void
  showNotice: (notice: string | null) => void
  run: <T>(work: (commands: Commands) => Promise<T>, failure: string) => Promise<T | undefined>
}

export const useApp = create<AppState>((set, get) => ({
  token: readStored(TOKEN_KEY),
  status: 'connecting',
  everOnline: false,
  version: 0,
  live: emptyLive(),
  daemonName: '',
  chatID: null,
  drawer: 'none',
  detailsTab: 'task',
  projectFilter: null,
  search: '',
  reviewing: false,
  composing: false,
  diffs: {},
  notice: null,
  session: null,

  setToken: (token) => {
    writeStored(TOKEN_KEY, token)
    set({ token })
  },

  connect: (options) => {
    get().session?.connection.stop()
    const replica = new Replica(options.readSnapshot)
    const connection = new Connection({
      url: options.url,
      token: options.token,
      replica,
      socket: options.socket,
      delays: options.delays,
      onStatus: (status, detail) => {
        set((state) => ({ status, statusDetail: detail, everOnline: state.everOnline || status === 'online' }))
        if (status === 'unauthorized') get().setToken(null)
      },
      onReplica: () => set({ version: replica.version }),
      onLive: (live) => set({ live }),
      onWelcome: (welcome) => set({ daemonName: welcome.daemon.name }),
    })
    set({ session: { connection, replica, commands: commands(connection) }, status: 'connecting', everOnline: false, diffs: {} })
    connection.start()
  },

  disconnect: () => {
    get().session?.connection.stop()
    set({ session: null })
  },

  openChat: (chatID) => {
    set({ chatID, drawer: 'none', reviewing: false, composing: false })
    void get().session?.commands.markViewed(chatID).catch(() => undefined)
  },
  setDrawer: (drawer) => set({ drawer }),
  setDetailsTab: (detailsTab) => set({ detailsTab }),
  setProjectFilter: (projectFilter) => set({ projectFilter }),
  setSearch: (search) => set({ search }),
  setReviewing: (reviewing) => set({ reviewing, drawer: 'none' }),
  setComposing: (composing) => set({ composing, drawer: 'none' }),
  showNotice: (notice) => set({ notice }),

  loadDiff: (runID, force = false) => {
    const session = get().session
    const current = get().diffs[runID]
    if (!session || (!force && current && current.status !== 'error')) return
    set((state) => ({ diffs: { ...state.diffs, [runID]: { status: 'loading' } } }))
    session.commands.diffSummary(runID).then(
      (diff) => set((state) => ({ diffs: { ...state.diffs, [runID]: { status: 'ready', diff } } })),
      (error: Error) => set((state) => ({ diffs: { ...state.diffs, [runID]: { status: 'error', message: error.message } } })),
    )
  },

  run: async (work, failure) => {
    const session = get().session
    if (!session) return undefined
    try {
      return await work(session.commands)
    } catch (error) {
      set({ notice: `${failure}: ${(error as Error).message}` })
      return undefined
    }
  },
}))

let recordsCache: { replica: Replica | null; version: number; records: Records } | null = null

export function selectRecords(state: AppState): Records {
  const replica = state.session?.replica ?? null
  if (recordsCache && recordsCache.replica === replica && recordsCache.version === state.version) return recordsCache.records
  const records = replica ? readRecords(replica) : readRecords(new Replica(async () => new Map()))
  recordsCache = { replica, version: state.version, records }
  return records
}

let summaryCache: { records: Records; live: LiveState; value: { open: ChatSummary[]; closed: ChatSummary[] } } | null = null

export function selectSummaries(state: AppState): { open: ChatSummary[]; closed: ChatSummary[] } {
  const records = selectRecords(state)
  if (summaryCache && summaryCache.records === records && summaryCache.live === state.live) return summaryCache.value
  const value = chatSummaries(records, state.live)
  summaryCache = { records, live: state.live, value }
  return value
}

export function selectGroups(state: AppState): Record<ChatGroup, ChatSummary[]> {
  const summaries = selectSummaries(state)
  const open = filterChats(summaries.open, state.projectFilter, state.search)
  const closed = filterChats(summaries.closed, state.projectFilter, state.search)
  const groups = groupChats(open)
  groups.finished = [...groups.finished, ...closed]
  return groups
}

export function selectCurrent(state: AppState): ChatSummary | null {
  const summaries = selectSummaries(state)
  const all = [...summaries.open, ...summaries.closed]
  if (state.chatID !== null) {
    const found = all.find((summary) => summary.chat.id === state.chatID)
    if (found) return found
  }
  return groupChats(summaries.open).needsYou[0] ?? summaries.open[0] ?? summaries.closed[0] ?? null
}

export function selectAttentionCount(state: AppState): number {
  return selectSummaries(state).open.filter((summary) => summary.stage === 'needsYou' || summary.stage === 'stuck').length
}
