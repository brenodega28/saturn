import { parse as parseYAML } from 'yaml'
import type { Replica, Row, Value } from './replica'

export interface Project {
  id: number
  name: string
  path: string
  host: string | null
  isOpen: boolean
  runCommand: string
}

export interface Chat {
  id: number
  projectId: number
  title: string
  workflow: string | null
  status: string
  closedAt: Date | null
  closeReason: string | null
  finishedAt: Date | null
  viewedAt: Date | null
  leadModel: string | null
  leadEffort: string | null
  createdAt: Date
  updatedAt: Date
}

export interface Run {
  id: number
  projectId: number
  taskId: number
  workflow: string
  currentStep: string | null
  status: RunStatus
  outcome: string | null
  costUSD: number
  startedAt: Date
  endedAt: Date | null
  title: string
  workflowSnapshot: string
  engineState: string
  lastError: string | null
  deliveryBranch: string | null
  baseBranch: string | null
  mergedAt: Date | null
  pushedAt: Date | null
  linesChanged: number | null
  filesChanged: number | null
}

export type RunStatus = 'pending' | 'running' | 'waitingOnYou' | 'paused' | 'interrupted' | 'succeeded' | 'failed' | 'cancelled'
export type AgentKind = 'lead' | 'builder' | 'checker'

export interface Agent {
  id: number
  projectId: number
  runId: number | null
  taskId: number | null
  runStepId: number | null
  role: string
  name: string
  branch: string | null
  baseBranch: string | null
  status: string
  model: string
  task: string
  archivedAt: Date | null
  createdAt: Date
}

export interface LeadMessage {
  id: number
  projectId: number
  taskId: number
  kind: string
  text: string
  workflow: string | null
  title: string | null
  status: string | null
  runId: number | null
  createdAt: Date
  permissionRequestId: number | null
  permissionStatus: string | null
  capability: string | null
}

export interface HumanQuestion {
  question: string
  options: string[]
}

export interface ChatRequest {
  id: number
  projectId: number
  taskId: number | null
  runId: number | null
  agentId: number | null
  kind: string
  title: string
  body: string
  status: string
  response: string | null
  questions: HumanQuestion[]
  createdAt: Date
  resolvedAt: Date | null
}

export interface RunStep {
  id: number
  runId: number
  stepId: string
  iteration: number
  status: string
  outcome: string | null
  output: string | null
  costUSD: number
  startedAt: Date
  endedAt: Date | null
}

export interface WorkflowStep {
  id: string
  type: string
  title?: string
  agent?: AgentKind
  maxRounds?: number
}

export interface Workflow {
  name: string
  steps: WorkflowStep[]
}

export interface RunHold {
  reason: string
  stepId: string
  requestId?: number
  message: string
}

export function date(value: Value | undefined): Date | null {
  if (value === null || value === undefined) return null
  if (typeof value === 'number') return new Date(value * 1000)
  const text = String(value)
  const iso = /^\d{4}-\d{2}-\d{2} /.test(text) ? text.replace(' ', 'T') + (/[zZ]|[+-]\d\d:?\d\d$/.test(text) ? '' : 'Z') : text
  const parsed = new Date(iso)
  return Number.isNaN(parsed.getTime()) ? null : parsed
}

function text(value: Value | undefined): string {
  if (value === null || value === undefined) return ''
  return typeof value === 'string' ? value : String(value)
}

function optionalText(value: Value | undefined): string | null {
  return value === null || value === undefined ? null : text(value)
}

function num(value: Value | undefined): number {
  return typeof value === 'number' ? value : Number(value ?? 0) || 0
}

function optionalNum(value: Value | undefined): number | null {
  return value === null || value === undefined ? null : num(value)
}

function json<T>(value: Value | undefined, fallback: T): T {
  if (typeof value !== 'string' || value === '') return fallback
  try {
    return JSON.parse(value) as T
  } catch {
    return fallback
  }
}

export function toProject(row: Row): Project {
  const settings = json<{ runCommand?: string }>(row.settings, {})
  return {
    id: row.rowid, name: text(row.name), path: text(row.path), host: optionalText(row.host),
    isOpen: num(row.isOpen) === 1, runCommand: settings.runCommand ?? '',
  }
}

export function toChat(row: Row): Chat {
  return {
    id: row.rowid, projectId: num(row.projectId), title: text(row.title), workflow: optionalText(row.workflow), status: text(row.status),
    closedAt: date(row.closedAt), closeReason: optionalText(row.closeReason), finishedAt: date(row.finishedAt), viewedAt: date(row.viewedAt),
    leadModel: optionalText(row.leadModel), leadEffort: optionalText(row.leadEffort),
    createdAt: date(row.createdAt) ?? new Date(0), updatedAt: date(row.updatedAt) ?? new Date(0),
  }
}

export function toRun(row: Row): Run {
  return {
    id: row.rowid, projectId: num(row.projectId), taskId: num(row.taskId), workflow: text(row.workflow), currentStep: optionalText(row.currentStep),
    status: text(row.status) as RunStatus, outcome: optionalText(row.outcome), costUSD: num(row.costUSD),
    startedAt: date(row.startedAt) ?? new Date(0), endedAt: date(row.endedAt), title: text(row.title),
    workflowSnapshot: text(row.workflowSnapshot), engineState: text(row.engineState) || '{}', lastError: optionalText(row.lastError),
    deliveryBranch: optionalText(row.deliveryBranch), baseBranch: optionalText(row.baseBranch),
    mergedAt: date(row.mergedAt), pushedAt: date(row.pushedAt), linesChanged: optionalNum(row.linesChanged), filesChanged: optionalNum(row.filesChanged),
  }
}

export function toAgent(row: Row): Agent {
  return {
    id: row.rowid, projectId: num(row.projectId), runId: optionalNum(row.runId), taskId: optionalNum(row.taskId), runStepId: optionalNum(row.runStepId),
    role: text(row.role), name: text(row.name), branch: optionalText(row.branch), baseBranch: optionalText(row.baseBranch),
    status: text(row.status), model: text(row.model), task: text(row.task), archivedAt: date(row.archivedAt), createdAt: date(row.createdAt) ?? new Date(0),
  }
}

export function toLeadMessage(row: Row): LeadMessage {
  return {
    id: row.rowid, projectId: num(row.projectId), taskId: num(row.taskId), kind: text(row.kind), text: text(row.text),
    workflow: optionalText(row.workflow), title: optionalText(row.title), status: optionalText(row.status), runId: optionalNum(row.runId),
    createdAt: date(row.createdAt) ?? new Date(0), permissionRequestId: optionalNum(row.permissionRequestId),
    permissionStatus: optionalText(row.permissionStatus), capability: optionalText(row.capability),
  }
}

export function toChatRequest(row: Row): ChatRequest {
  const questions = json<Array<{ question: string; options?: string[] }>>(row.questions, [])
  return {
    id: row.rowid, projectId: num(row.projectId), taskId: optionalNum(row.taskId), runId: optionalNum(row.runId), agentId: optionalNum(row.agentId),
    kind: text(row.kind), title: text(row.title), body: text(row.body), status: text(row.status), response: optionalText(row.response),
    questions: questions.map((question) => ({ question: question.question, options: question.options ?? [] })),
    createdAt: date(row.createdAt) ?? new Date(0), resolvedAt: date(row.resolvedAt),
  }
}

export function toRunStep(row: Row): RunStep {
  return {
    id: row.rowid, runId: num(row.runId), stepId: text(row.stepId), iteration: num(row.iteration) || 1, status: text(row.status),
    outcome: optionalText(row.outcome), output: optionalText(row.output), costUSD: num(row.costUSD),
    startedAt: date(row.startedAt) ?? new Date(0), endedAt: date(row.endedAt),
  }
}

export function agentKind(agent: Pick<Agent, 'role'>): AgentKind {
  if (agent.role === 'lead' || agent.role === 'builder' || agent.role === 'checker') return agent.role
  return guessKind(agent.role)
}

export function guessKind(role: string): AgentKind {
  const lower = role.toLowerCase()
  if (lower.includes('lead')) return 'lead'
  if (['review', 'check', 'qa', 'test', 'audit'].some((word) => lower.includes(word))) return 'checker'
  return 'builder'
}

const workflowCache = new Map<string, Workflow | null>()

export function runWorkflow(run: Pick<Run, 'workflowSnapshot'>): Workflow | null {
  const source = run.workflowSnapshot
  if (!source) return null
  if (workflowCache.has(source)) return workflowCache.get(source) ?? null
  let workflow: Workflow | null = null
  try {
    const parsed = parseYAML(source) as { name?: string; steps?: Array<Record<string, unknown>> } | null
    if (parsed && Array.isArray(parsed.steps)) {
      workflow = {
        name: String(parsed.name ?? ''),
        steps: parsed.steps.map((step) => {
          const named = typeof step.agent === 'string' ? step.agent.trim() : ''
          const legacy = typeof step.role === 'string' ? step.role : undefined
          const agent = named === 'lead' || named === 'builder' || named === 'checker' ? named : !named && legacy ? guessKind(legacy) : undefined
          return {
            id: String(step.id ?? ''), type: String(step.type ?? 'agent'), title: typeof step.title === 'string' ? step.title : undefined,
            agent, maxRounds: typeof step.max_rounds === 'number' ? step.max_rounds : undefined,
          }
        }),
      }
    }
  } catch {
    workflow = null
  }
  workflowCache.set(source, workflow)
  return workflow
}

export function runHold(run: Pick<Run, 'engineState' | 'status'>): RunHold | null {
  if (!['waitingOnYou', 'running', 'paused', 'pending', 'interrupted'].includes(run.status)) return null
  try {
    const state = JSON.parse(run.engineState) as { hold?: RunHold }
    return state.hold ?? null
  } catch {
    return null
  }
}

export function isActiveRun(run: Pick<Run, 'status'>): boolean {
  return ['pending', 'running', 'waitingOnYou', 'paused', 'interrupted'].includes(run.status)
}

export interface Records {
  projects: Project[]
  chats: Chat[]
  runs: Run[]
  agents: Agent[]
  messages: LeadMessage[]
  requests: ChatRequest[]
  steps: RunStep[]
  usage: Array<{ runId: number | null; agentId: number | null; costUSD: number; recordedAt: Date | null }>
}

export function readRecords(replica: Replica): Records {
  return {
    projects: replica.rows('project').map(toProject),
    chats: replica.rows('task').map(toChat),
    runs: replica.rows('run').map(toRun),
    agents: replica.rows('agent').map(toAgent),
    messages: replica.rows('leadMessage').map(toLeadMessage),
    requests: replica.rows('chatRequest').map(toChatRequest),
    steps: replica.rows('runStep').map(toRunStep),
    usage: replica.rows('usage').map((row) => ({
      runId: optionalNum(row.runId), agentId: optionalNum(row.agentId), costUSD: num(row.costUSD), recordedAt: date(row.recordedAt),
    })),
  }
}
