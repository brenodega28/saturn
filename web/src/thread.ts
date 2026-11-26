import type { LiveState } from './protocol'
import type { ChatStage, ChatSummary } from './chats'
import { chatOfAgent, leadAgent, needsAttention } from './chats'
import type { Agent, ChatRequest, LeadMessage, Records, Run, RunHold, RunStep, Workflow } from './records'
import { agentKind, isActiveRun, runWorkflow } from './records'

export type Tone = 'need' | 'stuck' | 'build' | 'review' | 'done' | 'idle'

export interface SpecInfo {
  version: number
  criteria: number
  url?: string
}

export type ThreadItem =
  | { type: 'user'; id: string; at: Date; message: LeadMessage }
  | { type: 'lead'; id: string; at: Date; message: LeadMessage }
  | { type: 'note'; id: string; at: Date; text: string }
  | { type: 'spec'; id: string; at: Date; message: LeadMessage; info: SpecInfo }
  | { type: 'proposal'; id: string; at: Date; message: LeadMessage }
  | { type: 'permission'; id: string; at: Date; message: LeadMessage }
  | { type: 'question'; id: string; at: Date; request: ChatRequest }
  | { type: 'approval'; id: string; at: Date; request: ChatRequest }
  | { type: 'problem'; id: string; at: Date; request: ChatRequest }
  | { type: 'events'; id: string; at: Date; run: Run; events: RunEvent[] }

export interface RunEvent {
  id: string
  title: string
  detail: string
  tone: Tone
  kind: Exclude<ReturnType<typeof agentKind>, never>
  agent?: Agent
}

export function stepTitle(stepID: string, workflow: Workflow | null): string {
  const step = workflow?.steps.find((candidate) => candidate.id === stepID)
  if (step?.title) return step.title
  return stepID.replace(/[_-]+/g, ' ').replace(/^\w/, (letter) => letter.toUpperCase())
}

export function outcomeTitle(outcome: string): string {
  return outcome.replace(/[_-]+/g, ' ').replace(/^\w/, (letter) => letter.toUpperCase())
}

export function stepTone(status: string): Tone {
  switch (status) {
    case 'running': return 'build'
    case 'waitingOnYou': return 'need'
    case 'succeeded': return 'done'
    case 'failed': return 'stuck'
    default: return 'idle'
  }
}

export function statusTitle(status: string): string {
  switch (status) {
    case 'running': return 'Running'
    case 'waitingOnYou': return 'Waiting for you'
    case 'succeeded': return 'Done'
    case 'failed': return 'Failed'
    case 'cancelled': return 'Cancelled'
    case 'interrupted': return 'Interrupted'
    default: return status
  }
}

export function stepSummary(step: RunStep): string | undefined {
  if (!step.output) return undefined
  try {
    const output = JSON.parse(step.output) as { summary?: string; verdict?: { summary?: string } }
    return output.summary ?? output.verdict?.summary ?? undefined
  } catch {
    return undefined
  }
}

function specInfo(message: LeadMessage): SpecInfo {
  try {
    const info = JSON.parse(message.text) as Partial<SpecInfo>
    return { version: info.version ?? 1, criteria: info.criteria ?? 0, url: info.url }
  } catch {
    return { version: 1, criteria: 0 }
  }
}

export function runEvents(records: Records, run: Run): RunEvent[] {
  const workflow = runWorkflow(run)
  const agents = records.agents.filter((agent) => agent.runId === run.id)
  return records.steps
    .filter((step) => step.runId === run.id)
    .sort((a, b) => a.startedAt.getTime() - b.startedAt.getTime() || a.id - b.id)
    .map((step) => {
      const agent = agents.find((candidate) => candidate.runStepId === step.id)
      const definition = workflow?.steps.find((candidate) => candidate.id === step.stepId)
      const name = agent?.name ?? stepTitle(step.stepId, workflow)
      const status = step.outcome ? outcomeTitle(step.outcome) : statusTitle(step.status)
      const title = agent ? `${name} · ${stepTitle(step.stepId, workflow)}` : name
      return {
        id: `step-${step.id}`, title, detail: stepSummary(step) ?? status, tone: stepTone(step.status),
        kind: agent ? agentKind(agent) : definition?.agent ?? (definition?.type === 'check' || definition?.type === 'gates' ? 'checker' : 'builder'),
        agent,
      }
    })
}

export function chatThread(records: Records, chatID: number): ThreadItem[] {
  const items: ThreadItem[] = []
  for (const message of records.messages) {
    if (message.taskId !== chatID) continue
    const base = { id: `m-${message.id}`, at: message.createdAt, message }
    switch (message.kind) {
      case 'user': items.push({ type: 'user', ...base }); break
      case 'lead': items.push({ type: 'lead', ...base }); break
      case 'specDraft': items.push({ type: 'spec', ...base, info: specInfo(message) }); break
      case 'proposal': items.push({ type: 'proposal', ...base }); break
      case 'permission': items.push({ type: 'permission', ...base }); break
      case 'note':
      case 'specFeedback':
        items.push({ type: 'note', id: base.id, at: base.at, text: message.text })
        break
      default: break
    }
  }
  for (const request of records.requests) {
    if (request.taskId !== chatID) continue
    const base = { id: `r-${request.id}`, at: request.createdAt, request }
    if (request.kind === 'question') items.push({ type: 'question', ...base })
    else if (request.kind === 'approval' || request.kind === 'plan_approval' || request.kind === 'gate') items.push({ type: 'approval', ...base })
    else if (request.kind === 'failure' || request.kind === 'loop_limit') items.push({ type: 'problem', ...base })
    else if (request.kind === 'notice' && request.status === 'open') items.push({ type: 'note', id: base.id, at: base.at, text: request.title })
  }
  for (const run of records.runs) {
    if (run.taskId !== chatID) continue
    const events = runEvents(records, run)
    if (events.length > 0) items.push({ type: 'events', id: `run-${run.id}`, at: run.startedAt, run, events })
  }
  return items.sort((a, b) => a.at.getTime() - b.at.getTime() || a.id.localeCompare(b.id))
}

export interface CheckRow {
  name: string
  status: 'passed' | 'failed' | 'running'
  durationSeconds: number
}

export type ChecksState =
  | { kind: 'waitingForWorkers' }
  | { kind: 'notStarted' }
  | { kind: 'running'; round: number }
  | { kind: 'failed'; round: number; maxRounds: number }
  | { kind: 'exhausted'; round: number }
  | { kind: 'passed'; count: number }

export interface ChatChecks {
  state: ChecksState
  rows: CheckRow[]
}

interface CheckReport {
  results: Array<{ name: string; status: string; durationSeconds: number }>
}

function checkReports(step: RunStep): CheckReport[] {
  if (!step.output) return []
  try {
    return (JSON.parse(step.output) as { checks?: CheckReport[] }).checks ?? []
  } catch {
    return []
  }
}

export function chatChecks(run: Run | null, steps: RunStep[], hold: RunHold | null, hasWorkers: boolean): ChatChecks {
  const idle: ChatChecks = { state: { kind: hasWorkers ? 'notStarted' : 'waitingForWorkers' }, rows: [] }
  if (!run) return idle
  const workflow = runWorkflow(run)
  const isCheck = (step: RunStep) => workflow?.steps.find((candidate) => candidate.id === step.stepId)?.type === 'check'
  const checkSteps = steps
    .filter((step) => step.runId === run.id && (isCheck(step) || checkReports(step).length > 0))
    .sort((a, b) => a.startedAt.getTime() - b.startedAt.getTime() || a.id - b.id)
  const latest = checkSteps.at(-1)
  if (!latest) return idle
  const reports = [...checkSteps].reverse().map(checkReports).find((list) => list.length > 0) ?? []
  const running = latest.status === 'running'
  const order: string[] = []
  const merged = new Map<string, CheckRow>()
  for (const result of reports.flatMap((report) => report.results)) {
    if (!merged.has(result.name)) order.push(result.name)
    const row = merged.get(result.name) ?? { name: result.name, status: 'passed' as const, durationSeconds: 0 }
    if (result.status !== 'passed') row.status = 'failed'
    row.durationSeconds = Math.max(row.durationSeconds, result.durationSeconds ?? 0)
    merged.set(result.name, row)
  }
  const rows = order.map((name) => ({ ...merged.get(name)!, ...(running ? { status: 'running' as const } : {}) }))
  const round = latest.iteration
  if (hold && hold.reason === 'step_failed' && workflow?.steps.find((step) => step.id === hold.stepId)?.type === 'check') {
    return { state: { kind: 'exhausted', round }, rows }
  }
  if (running) return { state: { kind: 'running', round }, rows }
  const maxRounds = workflow?.steps.find((step) => step.id === latest.stepId)?.maxRounds ?? 3
  const passed = reports.every((report) => report.results.every((result) => result.status === 'passed'))
  if (reports.length === 0 || passed) return { state: { kind: 'passed', count: rows.length }, rows }
  return { state: { kind: 'failed', round, maxRounds }, rows }
}

export function checksLabel(checks: ChatChecks): string {
  const passed = checks.rows.filter((row) => row.status === 'passed').length
  switch (checks.state.kind) {
    case 'waitingForWorkers': return 'Waiting for workers'
    case 'notStarted': return 'Not run yet'
    case 'running': return `Running · round ${checks.state.round}`
    case 'failed': return `${passed} of ${checks.rows.length} passed`
    case 'exhausted': return `Failed after ${checks.state.round} rounds`
    case 'passed': return checks.state.count > 0 ? `${checks.state.count} of ${checks.state.count} passed` : 'Passed'
  }
}

export const STAGE_NAMES = ['Plan', 'Build', 'Review', 'Merge']

export function stageIndex(stage: ChatStage, hasRun: boolean): number {
  switch (stage) {
    case 'idle':
    case 'dropped':
      return 0
    case 'needsYou':
    case 'stuck':
      return hasRun ? 1 : 0
    case 'building': return 1
    case 'inReview': return 2
    case 'finished':
    case 'done':
      return STAGE_NAMES.length
  }
}

export interface ReviewReady {
  run: Run
  summary: string | null
  requestID: number | null
  needsApproval: boolean
}

export function reviewReady(records: Records, summary: ChatSummary): ReviewReady | null {
  const run = summary.latestRun
  if (!run) return null
  const hold = summary.hold
  const finishedUnmerged = run.status === 'succeeded' && !run.mergedAt && !run.pushedAt && (run.deliveryBranch !== null || (run.filesChanged ?? 0) > 0)
  const waitingApproval = hold?.reason === 'approval'
  if (!finishedUnmerged && !waitingApproval) return null
  const steps = records.steps.filter((step) => step.runId === run.id).sort((a, b) => b.startedAt.getTime() - a.startedAt.getTime())
  const text = steps.map(stepSummary).find((value) => value) ?? null
  return { run, summary: text ?? hold?.message ?? null, requestID: hold?.requestId ?? null, needsApproval: waitingApproval }
}

export interface Activity {
  agent?: Agent
  kind: ReturnType<typeof agentKind>
  text: string
}

export function currentActivity(records: Records, summary: ChatSummary, live: LiveState): Activity | null {
  const lead = leadAgent(records, summary.chat.id)
  const liveLead = lead ? live.agents.get(lead.id) : undefined
  if (lead && liveLead?.isRunning) return { agent: lead, kind: 'lead', text: 'Lead is thinking' }
  for (const worker of summary.workers) {
    if (!live.agents.get(worker.id)?.isRunning) continue
    const doing = firstLine(worker.task)
    return { agent: worker, kind: agentKind(worker), text: doing ? `${worker.name} is working on ${lowerFirst(doing)}` : `${worker.name} is working` }
  }
  if (lead && liveLead?.isQueued) return { agent: lead, kind: 'lead', text: 'Lead is queued' }
  return null
}

function lowerFirst(text: string): string {
  return text.replace(/^[A-Z](?![A-Z])/, (letter) => letter.toLowerCase())
}

export function firstLine(text: string): string {
  return (text.split('\n').find((line) => line.trim()) ?? '').trim()
}

export type WorkerState = 'working' | 'queued' | 'needsYou' | 'stuck' | 'done' | 'idle' | 'stopped'

export function workerState(agent: Agent, live: LiveState): WorkerState {
  const state = live.agents.get(agent.id)
  if (state?.isRunning) return 'working'
  if (state?.isQueued) return 'queued'
  switch (agent.status) {
    case 'needsInput': return 'needsYou'
    case 'failed':
    case 'interrupted':
      return 'stuck'
    case 'working':
    case 'reviewing':
      return 'working'
    case 'stopped': return 'stopped'
    case 'idle': return agent.runId !== null ? 'done' : 'idle'
    default: return 'idle'
  }
}

export const WORKER_LABEL: Record<WorkerState, string> = {
  working: 'Working', queued: 'Queued', needsYou: 'Needs you', stuck: 'Stuck', done: 'Done', idle: 'Idle', stopped: 'Stopped',
}

export const WORKER_TONE: Record<WorkerState, Tone> = {
  working: 'build', queued: 'idle', needsYou: 'need', stuck: 'stuck', done: 'done', idle: 'idle', stopped: 'idle',
}

export interface LogEntry {
  id: string
  at: Date
  who: string
  kind: ReturnType<typeof agentKind>
  busy: boolean
  tag: string
  tone: Tone
  text: string
}

const REQUEST_TITLES: Record<string, string> = {
  question: 'Question', plan_approval: 'Plan', pin_review: 'Pins', approval: 'Approval', failure: 'Failed', notice: 'Notice',
  loop_limit: 'Loop limit', budget: 'Budget', gate: 'Gates', permission: 'Permission',
}

export function chatLog(records: Records, summary: ChatSummary, live: LiveState): LogEntry[] {
  const chat = summary.chat
  const entries: LogEntry[] = [{
    id: 'chat', at: chat.createdAt, who: 'Lead', kind: 'lead', busy: false, tag: 'Started', tone: 'idle', text: `Chat opened in ${summary.project.name}`,
  }]
  const agentsByID = new Map(records.agents.map((agent) => [agent.id, agent]))
  for (const run of records.runs.filter((candidate) => candidate.taskId === chat.id)) {
    const workflow = runWorkflow(run)
    entries.push({ id: `run-${run.id}`, at: run.startedAt, who: 'Lead', kind: 'lead', busy: false, tag: 'Started', tone: 'build', text: `${run.title || 'Run'} started` })
    if (run.endedAt) {
      const [tag, tone]: [string, Tone] = run.status === 'succeeded' ? ['Finished', 'done'] : run.status === 'failed' ? ['Failed', 'stuck']
        : run.status === 'cancelled' || run.status === 'interrupted' ? ['Stopped', 'idle'] : ['Ended', 'idle']
      entries.push({ id: `run-end-${run.id}`, at: run.endedAt, who: 'Lead', kind: 'lead', busy: false, tag, tone, text: run.outcome ? outcomeTitle(run.outcome) : run.title || 'Run' })
    }
    for (const step of records.steps.filter((candidate) => candidate.runId === run.id)) {
      const agent = records.agents.find((candidate) => candidate.runStepId === step.id)
      const definition = workflow?.steps.find((candidate) => candidate.id === step.stepId)
      const isCheck = definition?.type === 'check' || definition?.type === 'gates'
      const status = step.outcome ? outcomeTitle(step.outcome) : statusTitle(step.status)
      const title = stepTitle(step.stepId, workflow)
      entries.push({
        id: `step-${step.id}`, at: step.endedAt ?? step.startedAt, who: agent?.name ?? 'Saturn',
        kind: agent ? agentKind(agent) : isCheck ? 'checker' : 'builder', busy: step.status === 'running',
        tag: isCheck ? (step.status === 'succeeded' ? 'Checks ✓' : step.status === 'failed' ? 'Checks ✕' : 'Checks') : title,
        tone: stepTone(step.status), text: isCheck ? `${title} · ${status}` : stepSummary(step) ?? status,
      })
    }
  }
  for (const request of records.requests.filter((candidate) => candidate.taskId === chat.id)) {
    const agent = request.agentId !== null ? agentsByID.get(request.agentId) : undefined
    const open = request.status === 'open'
    entries.push({
      id: `request-${request.id}`, at: request.createdAt, who: agent?.name ?? 'Lead', kind: agent ? agentKind(agent) : 'lead', busy: false,
      tag: REQUEST_TITLES[request.kind] ?? 'Request', tone: request.kind === 'failure' ? 'stuck' : open && request.kind !== 'notice' ? 'need' : 'idle',
      text: request.title,
    })
  }
  for (const worker of summary.workers) {
    entries.push({
      id: `worker-${worker.id}`, at: worker.createdAt, who: worker.name, kind: agentKind(worker), busy: workerState(worker, live) === 'working',
      tag: 'Started', tone: 'build', text: worker.branch ? `Started on ${worker.branch}` : 'Started on this chat',
    })
  }
  return entries.sort((a, b) => a.at.getTime() - b.at.getTime() || a.id.localeCompare(b.id))
}

export interface ProjectStats {
  active: number
  workersRunning: number
  needsYou: number
  finished: number
}

export function projectStats(summaries: { open: ChatSummary[]; closed: ChatSummary[] }, records: Records, live: LiveState, projectID: number): ProjectStats {
  const open = summaries.open.filter((summary) => summary.project.id === projectID)
  const closed = summaries.closed.filter((summary) => summary.project.id === projectID)
  const workersRunning = records.agents.filter((agent) => agent.projectId === projectID && agentKind(agent) !== 'lead' && live.agents.get(agent.id)?.isRunning).length
  return {
    active: open.filter((summary) => summary.stage !== 'finished').length,
    workersRunning,
    needsYou: open.filter((summary) => needsAttention(summary.stage)).length,
    finished: open.filter((summary) => summary.stage === 'finished').length + closed.filter((summary) => summary.stage === 'done').length,
  }
}

export function projectAgents(records: Records, projectID: number): Agent[] {
  return records.agents
    .filter((agent) => agent.projectId === projectID && !agent.archivedAt)
    .sort((a, b) => {
      const lead = Number(agentKind(b) === 'lead') - Number(agentKind(a) === 'lead')
      return lead || b.createdAt.getTime() - a.createdAt.getTime()
    })
}

export function chatBranch(summary: ChatSummary): { branch: string; base: string | null } | null {
  const run = summary.latestRun
  if (run?.deliveryBranch) return { branch: run.deliveryBranch, base: run.baseBranch }
  const worker = summary.workers.find((agent) => agent.branch)
  if (worker?.branch) return { branch: worker.branch, base: worker.baseBranch }
  return null
}

export function isRunActive(run: Run | null): boolean {
  return run ? isActiveRun(run) : false
}

export { chatOfAgent }
