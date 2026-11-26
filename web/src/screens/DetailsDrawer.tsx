import { useEffect, useMemo, useState } from 'react'
import type { ChatSummary } from '../chats'
import { STAGE_TITLES, STAGE_TONE } from '../chats'
import { clockTime, duration, elapsed, hostTitle, modelTitle, plural, shortTime } from '../format'
import { agentKind } from '../records'
import type { DetailsTab } from '../store'
import { selectCurrent, selectRecords, selectSummaries, useApp } from '../store'
import type { ChatChecks } from '../thread'
import {
  STAGE_NAMES, WORKER_LABEL, WORKER_TONE, chatBranch, chatChecks, chatLog, checksLabel, firstLine, isRunActive, projectAgents, projectStats,
  reviewReady, stageIndex, workerState,
} from '../thread'
import type { ICONS } from '../ui'
import { Avatar, Icon, IconButton, ProjectTile } from '../ui'
import { DiffCounts } from './Chat'

const TABS: Array<{ id: DetailsTab; name: string; icon: keyof typeof ICONS }> = [
  { id: 'task', name: 'Task', icon: 'task' }, { id: 'project', name: 'Project', icon: 'project' }, { id: 'log', name: 'Log', icon: 'log' },
]

export function DetailsDrawer() {
  const state = useApp()
  const summary = selectCurrent(state)
  const tab = TABS.find((candidate) => candidate.id === state.detailsTab) ?? TABS[0]
  return (
    <aside className="drawer right" aria-label="Chat details">
      <div className="details-header">
        <div className="tabs" role="tablist" aria-label="Details">
          {TABS.map((candidate) => (
            <button key={candidate.id} type="button" role="tab" className="tab" aria-selected={candidate.id === tab.id} aria-label={candidate.name}
              aria-controls="details-panel" onClick={() => state.setDetailsTab(candidate.id)}>
              <Icon name={candidate.icon} size={19} />
            </button>
          ))}
        </div>
        <h2 className="details-name">{tab.name}</h2>
        <IconButton label="Close details" icon="close" className="muted close-drawer" onClick={() => state.setDrawer('none')} />
      </div>
      <div className="details-body" id="details-panel" role="tabpanel" aria-label={tab.name}>
        {!summary && <p className="muted-text">Open a chat to see its details.</p>}
        {summary && tab.id === 'task' && <TaskPane summary={summary} />}
        {summary && tab.id === 'project' && <ProjectPane summary={summary} />}
        {summary && tab.id === 'log' && <LogPane summary={summary} />}
      </div>
      {summary && tab.id === 'task' && <TaskFooter summary={summary} />}
    </aside>
  )
}

function TaskPane({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const run = summary.latestRun
  useEffect(() => {
    if (run) state.loadDiff(run.id, isRunActive(run))
  }, [run?.id, run?.status, run?.linesChanged])
  const diff = run ? state.diffs[run.id] : undefined
  const current = stageIndex(summary.stage, run !== null)
  const tone = STAGE_TONE[summary.stage]
  const checks = chatChecks(run, records.steps, summary.hold, summary.workers.length > 0)
  const branch = chatBranch(summary)
  const started = run?.startedAt ?? summary.chat.createdAt
  const paths = diff?.status === 'ready' ? diff.diff.paths : []
  return (
    <div className="pane">
      <div className="task-heading">
        <span className="row">
          <span className={`pill bg-${tone} tone-${tone}`}><span className={`pill-dot fill-${tone}`} aria-hidden="true" />{STAGE_TITLES[summary.stage]}</span>
          <span className="when">Started {clockTime(started)} · {elapsed(started, run?.endedAt ?? new Date())}</span>
        </span>
        <h3>{summary.chat.title || 'New chat'}</h3>
      </div>
      <ol className="stages" aria-label="Stages">
        {STAGE_NAMES.map((name, index) => {
          const status = index < current ? 'done' : index === current ? 'current' : 'todo'
          return (
            <li key={name} className={status} aria-current={status === 'current' ? 'step' : undefined}
              style={status === 'current' ? { color: `var(--${tone === 'text2' ? 'text' : tone})` } : undefined}>
              <span className="bar" aria-hidden="true" style={status === 'current' ? { background: `var(--${tone === 'text2' ? 'text2' : tone})` } : undefined} />
              {name}<span className="sr-only">, {status === 'done' ? 'done' : status === 'current' ? 'current' : 'not started'}</span>
            </li>
          )
        })}
      </ol>
      <div className="list-card" aria-label="Branch and app">
        <div className="list-row">
          <span className="lead-icon"><Icon name="branch" size={18} /></span>
          <span className="body">
            <span className="main mono">{branch?.branch ?? 'No branch yet'}</span>
            <span className="sub">{branch ? `from ${branch.base ?? 'main'}` : 'Workers get a branch when they start'}</span>
          </span>
        </div>
        <div className="list-row">
          <span className="runner-dot"><span className="fill-idle" /></span>
          <span className="body">
            <span className="main">App runs from the Mac</span>
            <span className="sub mono">{summary.project.runCommand || 'No run command set'}</span>
          </span>
        </div>
        <div className="list-row">
          <span className="lead-icon"><Icon name="terminal" size={18} /></span>
          <span className="body">
            <span className="main">Output</span>
            <span className="sub">Open the app on the Mac to see its output</span>
          </span>
        </div>
      </div>
      <section className="section" aria-label="Changes">
        <h3>
          Changes
          {diff?.status === 'ready' && diff.diff.added + diff.diff.deleted > 0 && <DiffCounts added={diff.diff.added} deleted={diff.diff.deleted} />}
          {paths.length > 0 && <span className="aside">· {plural(paths.length, 'file')}</span>}
        </h3>
        {diff?.status === 'loading' && <p className="muted-text">Loading changes…</p>}
        {diff?.status === 'error' && <p className="muted-text">Couldn’t load the changes: {diff.message}</p>}
        {(!run || (diff?.status === 'ready' && paths.length === 0)) && <p className="muted-text">No changes yet.</p>}
        {paths.length > 0 && (
          <div className="list-card">
            {paths.slice(0, 8).map((path) => <div key={path} className="file-row"><span title={path}>{path}</span></div>)}
            {paths.length > 8 && (
              <button type="button" className="file-row hover" style={{ width: '100%', border: 0, borderTop: '1px solid var(--hair)', background: 'transparent', color: 'var(--link)' }}
                onClick={() => state.setReviewing(true)}>{paths.length - 8} more</button>
            )}
          </div>
        )}
      </section>
      <ChecksSection checks={checks} />
      <section className="section" aria-label="Workers">
        <h3>Workers{summary.workers.length > 0 && <span className="aside">{summary.workers.length}</span>}</h3>
        {summary.workers.length === 0 && <p className="muted-text">No workers on this chat yet.</p>}
        {summary.workers.map((agent) => {
          const worker = workerState(agent, state.live)
          return (
            <div key={agent.id} className="person">
              <Avatar kind={agentKind(agent)} name={agent.name} size={34} busy={worker === 'working'} />
              <span className="body">
                <span className="name">{agent.name}</span>
                <span className="sub">{firstLine(agent.task) || agent.branch || modelTitle(agent.model)}</span>
              </span>
              <span className={`state tone-${WORKER_TONE[worker]}`}>{WORKER_LABEL[worker]}</span>
            </div>
          )
        })}
      </section>
    </div>
  )
}

function ChecksSection({ checks }: { checks: ChatChecks }) {
  const kind = checks.state.kind
  const tone = kind === 'passed' ? 'done' : kind === 'failed' || kind === 'exhausted' ? 'stuck' : kind === 'running' ? 'build' : 'text2'
  return (
    <section className="section" aria-label="Checks">
      <h3>Checks<span className={`end tone-${tone}`}>{checksLabel(checks)}</span></h3>
      {checks.rows.length > 0 && (
        <div className="list-card">
          {checks.rows.map((row) => {
            const rowTone = row.status === 'passed' ? 'done' : row.status === 'failed' ? 'stuck' : 'build'
            return (
              <div key={row.name} className="check-row">
                <span className={`mark bg-${rowTone} tone-${rowTone}`} aria-hidden="true"><Icon name={row.status === 'failed' ? 'cross' : 'check'} size={11} stroke={3} /></span>
                <span className="name">{row.name}<span className="sr-only">, {row.status}</span></span>
                <span className="mono">{duration(row.durationSeconds)}</span>
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}

function TaskFooter({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const run = summary.latestRun
  const [busy, setBusy] = useState(false)
  const review = reviewReady(records, summary)
  const canPush = run !== null && run.status === 'succeeded' && run.deliveryBranch !== null && !run.pushedAt
  const push = async () => {
    if (!run) return
    setBusy(true)
    const result = await state.run((commands) => commands.push(run.id), 'Couldn’t push the branch')
    if (result !== undefined) state.showNotice(typeof result === 'string' && result ? result : 'Pushed.')
    setBusy(false)
  }
  return (
    <div className="details-footer">
      <button type="button" className="button primary grow" disabled={!run || (!review && !run.filesChanged && !run.deliveryBranch)} onClick={() => state.setReviewing(true)}>
        Review changes
      </button>
      <button type="button" className="button" disabled={!canPush || busy} onClick={push}>{run?.pushedAt ? 'Pushed' : 'Push'}</button>
    </div>
  )
}

function ProjectPane({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const summaries = selectSummaries(state)
  const project = summary.project
  const stats = projectStats(summaries, records, state.live, project.id)
  const agents = projectAgents(records, project.id)
  const chats = [...summaries.open, ...summaries.closed].filter((candidate) => candidate.project.id === project.id)
  const runs = records.runs.filter((run) => run.projectId === project.id)
  const last = chats.reduce<Date | null>((latest, candidate) => (!latest || candidate.lastActivity > latest ? candidate.lastActivity : latest), null)
  const merged = runs.filter((run) => run.mergedAt).length
  return (
    <div className="pane" style={{ gap: 20 }}>
      <div className="identity">
        <ProjectTile name={project.name} size={44} />
        <div className="body">
          <span className="name">{project.name}</span>
          <span className="where">{hostTitle(project.host)} · <span className="mono" style={{ fontSize: 12 }}>{project.path}</span></span>
        </div>
      </div>
      <section className="section" aria-label="Summary">
        <h3>Summary{last && <span className="end aside">last activity {shortTime(last)}</span>}</h3>
        <p className="summary-text">
          {plural(chats.length, 'chat')} and {plural(runs.length, 'run')} in this project{merged > 0 ? `, ${merged} merged` : ''}.
          {project.runCommand ? ` The app runs with ${project.runCommand}.` : ''}
        </p>
      </section>
      <div className="stats">
        <Stat value={stats.active} label="Active chats" />
        <Stat value={stats.workersRunning} label="Workers running" tone="build" />
        <Stat value={stats.needsYou} label="Needs you" tone="need" />
        <Stat value={stats.finished} label="Finished" tone="done" />
      </div>
      <section className="section" aria-label="Agents" style={{ gap: 4 }}>
        <h3>Agents<span className="aside">{agents.length}</span></h3>
        {agents.length === 0 && <p className="muted-text">No agents yet.</p>}
        {agents.map((agent) => {
          const worker = workerState(agent, state.live)
          const tone = WORKER_TONE[worker]
          return (
            <div key={agent.id} className="person" style={{ minHeight: 52 }}>
              <Avatar kind={agentKind(agent)} name={agent.name} size={36} busy={worker === 'working'} />
              <span className="body">
                <span className="name" style={{ fontWeight: 600 }}>{agent.name}</span>
                <span className="sub">{modelTitle(agent.model)} · {agentKind(agent) === 'lead' ? 'Lead' : agentKind(agent) === 'checker' ? 'Checker' : 'Builder'}</span>
              </span>
              <span className={`state tone-${tone}`}><span className={`fill-${tone}`} aria-hidden="true" />{WORKER_LABEL[worker]}</span>
            </div>
          )
        })}
      </section>
    </div>
  )
}

function Stat({ value, label, tone }: { value: number; label: string; tone?: string }) {
  return (
    <div className="stat">
      <span className={`value ${tone ? `tone-${tone}` : ''}`}>{value}</span>
      <span className="key">{label}</span>
    </div>
  )
}

const TAG_TONES: Record<string, [string, string]> = {
  need: ['var(--needBg)', 'var(--need)'], stuck: ['var(--stuckBg)', 'var(--stuck)'], build: ['var(--buildBg)', 'var(--build)'],
  review: ['var(--reviewBg)', 'var(--review)'], done: ['var(--doneBg)', 'var(--done)'], idle: ['var(--fill)', 'var(--text2)'],
}

function LogPane({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const entries = useMemo(() => chatLog(records, summary, state.live), [records, summary, state.live])
  return (
    <ol className="timeline" role="log" aria-label="Chat progress">
      {entries.map((entry) => {
        const [background, color] = TAG_TONES[entry.tone] ?? TAG_TONES.idle
        return (
          <li key={entry.id}>
            <span className="rail" aria-hidden="true" />
            <Avatar kind={entry.kind} name={entry.who} size={27} busy={entry.busy} />
            <span className="body">
              <span className="top">
                <span className="who">{entry.who}</span>
                <span className="tag" style={{ background, color }}>{entry.tag}</span>
                <time className="time" dateTime={entry.at.toISOString()}>{shortTime(entry.at)}</time>
              </span>
              <span className="text">{entry.text}</span>
            </span>
          </li>
        )
      })}
    </ol>
  )
}
