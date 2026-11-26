import type { LiveState } from './protocol'
import type { Agent, Chat, Project, Records, Run, RunHold, WorkflowStep } from './records'
import { agentKind, isActiveRun, runHold, runWorkflow } from './records'

export type ChatStage = 'needsYou' | 'stuck' | 'building' | 'inReview' | 'finished' | 'done' | 'dropped' | 'idle'
export type ChatGroup = 'needsYou' | 'inProgress' | 'notStarted' | 'finished'

export const GROUPS: ChatGroup[] = ['needsYou', 'inProgress', 'notStarted', 'finished']
export const GROUP_TITLES: Record<ChatGroup, string> = {
  needsYou: 'Needs you', inProgress: 'In progress', notStarted: 'Not started', finished: 'Finished',
}

export const STAGE_TITLES: Record<ChatStage, string> = {
  needsYou: 'Needs you', stuck: 'Stuck · needs you', building: 'Building', inReview: 'In review',
  finished: 'Finished', done: 'Resolved', dropped: 'Closed', idle: 'Open',
}

export const STAGE_TONE: Record<ChatStage, string> = {
  needsYou: 'need', stuck: 'stuck', building: 'build', inReview: 'review', finished: 'done', done: 'done', idle: 'idle', dropped: 'text2',
}

export interface StageFacts {
  closeReason?: string | null
  isClosed?: boolean
  isFinished?: boolean
  latestRun?: Pick<Run, 'status'> | null
  currentStep?: Pick<WorkflowStep, 'agent' | 'type'> | null
  hold?: Pick<RunHold, 'reason'> | null
  openRequests?: string[]
  pendingPermissions?: number
  hasOpenProposal?: boolean
  leadIsWorking?: boolean
}

const STUCK_KINDS = new Set(['failure', 'loop_limit'])
const STUCK_HOLDS = new Set(['step_failed', 'timed_out', 'loop_limit'])

export function chatStage(facts: StageFacts): ChatStage {
  if (facts.isClosed) return facts.closeReason === 'dropped' ? 'dropped' : 'done'
  const requests = facts.openRequests ?? []
  if (facts.hold && STUCK_HOLDS.has(facts.hold.reason)) return 'stuck'
  if (requests.some((kind) => STUCK_KINDS.has(kind))) return 'stuck'
  const run = facts.latestRun
  if (run && (run.status === 'failed' || run.status === 'interrupted')) return 'stuck'
  if (facts.hold || (facts.pendingPermissions ?? 0) > 0 || facts.hasOpenProposal) return 'needsYou'
  if (requests.some((kind) => kind !== 'notice' && kind !== 'pin_review')) return 'needsYou'
  if (run && isActiveRun(run)) {
    return facts.currentStep?.agent === 'checker' || facts.currentStep?.type === 'gates' ? 'inReview' : 'building'
  }
  if (facts.leadIsWorking) return 'building'
  if (facts.isFinished) return 'finished'
  if (run && run.status === 'succeeded') return 'finished'
  return 'idle'
}

export function needsAttention(stage: ChatStage): boolean {
  return stage === 'needsYou' || stage === 'stuck'
}

export function groupOf(stage: ChatStage): ChatGroup | null {
  switch (stage) {
    case 'needsYou':
    case 'stuck':
      return 'needsYou'
    case 'inReview':
    case 'building':
      return 'inProgress'
    case 'idle':
      return 'notStarted'
    case 'finished':
      return 'finished'
    default:
      return null
  }
}

const GROUP_RANK: Record<ChatStage, number> = { needsYou: 0, stuck: 1, inReview: 2, building: 3, idle: 4, finished: 5, done: 6, dropped: 7 }

export function groupChats<T extends { stage: ChatStage; lastActivity: Date }>(items: T[]): Record<ChatGroup, T[]> {
  const sorted = items
    .map((item, offset) => ({ item, offset }))
    .sort((left, right) => {
      const rank = GROUP_RANK[left.item.stage] - GROUP_RANK[right.item.stage]
      if (rank !== 0) return rank
      const time = right.item.lastActivity.getTime() - left.item.lastActivity.getTime()
      if (time !== 0) return time
      return left.offset - right.offset
    })
  const groups: Record<ChatGroup, T[]> = { needsYou: [], inProgress: [], notStarted: [], finished: [] }
  for (const { item } of sorted) {
    const group = groupOf(item.stage)
    if (group) groups[group].push(item)
  }
  return groups
}

export interface ChatSummary {
  chat: Chat
  project: Project
  stage: ChatStage
  lastActivity: Date
  workers: Agent[]
  isUnread: boolean
  costUSD: number
  latestRun: Run | null
  hold: RunHold | null
}

function later(left: Date | undefined, right: Date): Date {
  return left && left > right ? left : right
}

export function latestRun(runs: Run[]): Run | null {
  let best: Run | null = null
  for (const run of runs) {
    if (!best || run.startedAt > best.startedAt || (run.startedAt.getTime() === best.startedAt.getTime() && run.id > best.id)) best = run
  }
  return best
}

export function chatSpend(records: Records): Map<number, number> {
  const runs = new Map(records.runs.map((run) => [run.id, run]))
  const agents = new Map(records.agents.map((agent) => [agent.id, agent]))
  const spend = new Map<number, number>()
  for (const entry of records.usage) {
    const run = entry.runId !== null ? runs.get(entry.runId) : undefined
    const agent = entry.agentId !== null ? agents.get(entry.agentId) : undefined
    const agentRun = agent?.runId !== null && agent?.runId !== undefined ? runs.get(agent.runId) : undefined
    const chatID = run?.taskId ?? agent?.taskId ?? agentRun?.taskId
    if (chatID === undefined || chatID === null) continue
    spend.set(chatID, (spend.get(chatID) ?? 0) + entry.costUSD)
  }
  return spend
}

export function leadAgent(records: Records, chatID: number): Agent | undefined {
  let lead: Agent | undefined
  for (const agent of records.agents) {
    if (agent.taskId === chatID && (!lead || agent.id < lead.id)) lead = agent
  }
  return lead
}

export function chatOfAgent(records: Records, agent: Agent): number | null {
  if (agent.taskId !== null) return agent.taskId
  if (agent.runId === null) return null
  return records.runs.find((run) => run.id === agent.runId)?.taskId ?? null
}

export function chatSummaries(records: Records, live: LiveState): { open: ChatSummary[]; closed: ChatSummary[] } {
  const projects = records.projects.filter((project) => project.isOpen)
  const projectIDs = new Set(projects.map((project) => project.id))
  const spend = chatSpend(records)
  const openRequests = new Map<number, string[]>()
  for (const request of records.requests) {
    if (request.status !== 'open' || request.taskId === null || !projectIDs.has(request.projectId)) continue
    openRequests.set(request.taskId, [...(openRequests.get(request.taskId) ?? []), request.kind])
  }
  const runsByChat = new Map<number, Run[]>()
  for (const run of records.runs) runsByChat.set(run.taskId, [...(runsByChat.get(run.taskId) ?? []), run])
  const chatOfRun = new Map(records.runs.map((run) => [run.id, run.taskId]))
  const activity = new Map<number, Date>()
  const touch = (chatID: number, at: Date | null) => {
    if (at) activity.set(chatID, later(activity.get(chatID), at))
  }
  const proposals = new Set<number>()
  const permissions = new Map<number, number>()
  const hasMessages = new Set<number>()
  const closedChats = new Set(records.chats.filter((chat) => chat.closedAt).map((chat) => chat.id))
  for (const message of records.messages) {
    hasMessages.add(message.taskId)
    if (message.kind !== 'user') touch(message.taskId, message.createdAt)
    if (message.kind === 'proposal' && message.status === 'open') proposals.add(message.taskId)
    if (message.kind === 'permission' && message.permissionStatus === 'pending' && !closedChats.has(message.taskId)) {
      permissions.set(message.taskId, (permissions.get(message.taskId) ?? 0) + 1)
    }
  }
  const hasRequests = new Set<number>()
  for (const request of records.requests) {
    if (request.taskId === null) continue
    hasRequests.add(request.taskId)
    touch(request.taskId, request.createdAt)
  }
  for (const run of records.runs) touch(run.taskId, run.endedAt ?? run.startedAt)
  const workersByChat = new Map<number, Agent[]>()
  const leads = new Map<number, Agent>()
  for (const agent of records.agents) {
    if (agent.taskId !== null) {
      const current = leads.get(agent.taskId)
      if (!current || agent.id < current.id) leads.set(agent.taskId, agent)
    }
  }
  for (const agent of [...records.agents].sort((a, b) => a.id - b.id)) {
    if (!projectIDs.has(agent.projectId) || agentKind(agent) === 'lead' || agent.archivedAt) continue
    const chatID = agent.taskId ?? (agent.runId !== null ? chatOfRun.get(agent.runId) : undefined)
    if (chatID === undefined || chatID === null) continue
    workersByChat.set(chatID, [...(workersByChat.get(chatID) ?? []), agent])
  }
  const open: ChatSummary[] = []
  const closed: ChatSummary[] = []
  for (const chat of records.chats) {
    if (!projectIDs.has(chat.projectId)) continue
    if (!runsByChat.has(chat.id) && !hasMessages.has(chat.id) && !hasRequests.has(chat.id)) continue
    const project = projects.find((candidate) => candidate.id === chat.projectId)!
    const latest = latestRun(runsByChat.get(chat.id) ?? [])
    const hold = latest ? runHold(latest) : null
    const lead = leads.get(chat.id)
    const liveLead = lead ? live.agents.get(lead.id) : undefined
    const step = latest?.currentStep ? runWorkflow(latest)?.steps.find((candidate) => candidate.id === latest.currentStep) : undefined
    const stage = chatStage({
      closeReason: chat.closeReason, isClosed: chat.closedAt !== null, isFinished: chat.finishedAt !== null && chat.closedAt === null,
      latestRun: latest, currentStep: step, hold, openRequests: openRequests.get(chat.id) ?? [],
      pendingPermissions: permissions.get(chat.id) ?? 0, hasOpenProposal: proposals.has(chat.id),
      leadIsWorking: liveLead ? liveLead.isRunning || liveLead.isQueued : false,
    })
    const last = activity.get(chat.id)
    const summary: ChatSummary = {
      chat, project, stage, lastActivity: later(last ?? chat.updatedAt, chat.createdAt), workers: workersByChat.get(chat.id) ?? [],
      isUnread: last ? last > (chat.viewedAt ?? chat.createdAt) : false, costUSD: spend.get(chat.id) ?? 0, latestRun: latest, hold,
    }
    if (chat.closedAt) closed.push(summary)
    else open.push(summary)
  }
  const byKey = (summary: ChatSummary) => `${summary.chat.id}`.padStart(12, '0')
  open.sort((a, b) => b.lastActivity.getTime() - a.lastActivity.getTime() || (byKey(b) > byKey(a) ? 1 : -1))
  closed.sort((a, b) => (b.chat.closedAt?.getTime() ?? 0) - (a.chat.closedAt?.getTime() ?? 0) || b.chat.id - a.chat.id)
  return { open, closed }
}

export function filterChats(summaries: ChatSummary[], projectID: number | null, search: string): ChatSummary[] {
  const query = search.trim().toLowerCase()
  return summaries.filter((summary) => {
    if (projectID !== null && summary.project.id !== projectID) return false
    if (!query) return true
    return summary.chat.title.toLowerCase().includes(query) || summary.project.name.toLowerCase().includes(query)
  })
}
