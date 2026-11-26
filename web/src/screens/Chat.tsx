import { useEffect, useMemo, useRef, useState } from 'react'
import type { ChatSummary } from '../chats'
import { STAGE_TITLES, STAGE_TONE } from '../chats'
import type { ChatAttachment } from '../commands'
import { clockTime, effortTitle, formatCost, hostTitle, modelTitle, plural, workflowTitle } from '../format'
import { newUUID, toBase64 } from '../protocol'
import type { ChatRequest, LeadMessage } from '../records'
import { selectAttentionCount, selectCurrent, selectRecords, selectSummaries, useApp } from '../store'
import type { RunEvent, ThreadItem } from '../thread'
import { chatChecks, chatThread, checksLabel, currentActivity, reviewReady } from '../thread'
import { Avatar, Dots, Icon, IconButton, ProjectTile, StatusDot } from '../ui'

export function ChatScreen({ composing, onComposed }: { composing: boolean; onComposed: () => void }) {
  const state = useApp()
  const summary = selectCurrent(state)
  const attention = selectAttentionCount(state)
  const records = selectRecords(state)
  const review = summary ? reviewReady(records, summary) : null
  const showOffline = state.everOnline && state.status !== 'online'
  return (
    <main className="chat-screen" aria-label="Chat">
      <header className="chat-header">
        <IconButton label="Open chats" icon="menu" className="open-chats" expanded={state.drawer === 'left'} onClick={() => state.setDrawer('left')}>
          {attention > 0 && <span className="badge-dot fill-need" role="img" aria-label={`${plural(attention, 'chat')} need${attention === 1 ? 's' : ''} you`} />}
        </IconButton>
        {composing || !summary ? <NewChatHeading /> : <ChatHeading summary={summary} />}
        <IconButton label="Open task details" icon="details" className="open-details" expanded={state.drawer === 'right'} onClick={() => state.setDrawer('right')}>
          {summary && !composing && (review || summary.stage === 'needsYou' || summary.stage === 'stuck') && (
            <span className={`badge-dot fill-${review ? 'review' : STAGE_TONE[summary.stage]}`} aria-hidden="true" />
          )}
        </IconButton>
      </header>
      {showOffline && <OfflineBanner />}
      {composing || !summary ? <NewChatLog /> : <ChatLog summary={summary} />}
      {state.notice && (
        <div className="notice" role="alert">
          <span>{state.notice}</span>
          <IconButton label="Dismiss" icon="close" className="muted" onClick={() => state.showNotice(null)} />
        </div>
      )}
      <Composer summary={composing ? null : summary} onComposed={onComposed} />
    </main>
  )
}

export function OfflineBanner() {
  const status = useApp((state) => state.status)
  const reconnect = () => useApp.getState().session?.connection.reconnectNow()
  return (
    <div className="offline-banner" role="status">
      {status === 'syncing' ? 'Catching up with Saturn…' : 'Offline · reconnecting to Saturn'}
      {status === 'offline' && <button type="button" className="button small" onClick={reconnect}>Retry</button>}
    </div>
  )
}

function ChatHeading({ summary }: { summary: ChatSummary }) {
  const tone = STAGE_TONE[summary.stage]
  const pulse = summary.stage === 'building' || summary.stage === 'inReview'
  return (
    <div className="chat-heading">
      <span className="chat-title-line">
        <StatusDot tone={tone} label={STAGE_TITLES[summary.stage]} pulse={pulse} />
        <h1 className="chat-title">{summary.chat.title || 'New chat'}</h1>
      </span>
      <span className="chat-subtitle">
        <ProjectTile name={summary.project.name} size={12} />
        {summary.project.name} · {hostTitle(summary.project.host)}
        {summary.costUSD > 0 && <> · <span className="mono">{formatCost(summary.costUSD)}</span></>}
      </span>
    </div>
  )
}

function NewChatHeading() {
  return (
    <div className="chat-heading">
      <span className="chat-title-line"><h1 className="chat-title">New chat</h1></span>
      <span className="chat-subtitle">Tell the Lead what you need</span>
    </div>
  )
}

function useStickToBottom(dependency: unknown) {
  const ref = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const element = ref.current
    if (element) element.scrollTop = element.scrollHeight
  }, [dependency])
  return ref
}

function ChatLog({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const review = reviewReady(records, summary)
  const items = useMemo(
    () => chatThread(records, summary.chat.id).filter((item) => !(item.type === 'approval' && item.request.id === review?.requestID)),
    [records, summary.chat.id, review?.requestID],
  )
  const activity = currentActivity(records, summary, state.live)
  const ref = useStickToBottom(`${summary.chat.id}-${items.length}-${activity?.text}-${review?.run.id}`)
  return (
    <div className="chat-log" role="log" aria-label="Chat with the Lead" ref={ref}>
      <div className="chat-log-inner">
        {items.length === 0 && <p className="note-line">No messages yet.</p>}
        {items.map((item) => <ThreadRow key={item.id} item={item} />)}
        {review && <ReviewCard summary={summary} />}
        {activity && (
          <span className="typing" role="status">
            <Avatar kind={activity.kind} name={activity.agent?.name} size={20} busy />
            <span>{activity.text}</span>
            <Dots />
          </span>
        )}
      </div>
    </div>
  )
}

function NewChatLog() {
  const state = useApp()
  const summaries = selectSummaries(state)
  const projects = selectRecords(state).projects.filter((project) => project.isOpen)
  const empty = summaries.open.length === 0 && summaries.closed.length === 0
  return (
    <div className="chat-log" role="log" aria-label="New chat">
      <div className="empty">
        <h2>{empty ? 'No chats yet' : 'Start a chat'}</h2>
        {projects.length === 0
          ? <span>Open a project in Saturn on your Mac. Chats and workers live inside a project.</span>
          : <span>Tell the Lead what you need. It writes a spec, starts the workers and brings the result back here.</span>}
      </div>
    </div>
  )
}

function ThreadRow({ item }: { item: ThreadItem }) {
  switch (item.type) {
    case 'user': return <div className="bubble">{item.message.text}</div>
    case 'lead': return <LeadText message={item.message} />
    case 'note': return <p className="note-line">{item.text}</p>
    case 'spec': return <SpecCard message={item.message} criteria={item.info.criteria} version={item.info.version} />
    case 'proposal': return <ProposalCard message={item.message} />
    case 'permission': return <PermissionCard message={item.message} />
    case 'question': return <QuestionCard request={item.request} />
    case 'approval': return <ApprovalCard request={item.request} />
    case 'problem': return <ProblemCard request={item.request} />
    case 'events': return <EventRows events={item.events} />
  }
}

function LeadText({ message }: { message: LeadMessage }) {
  return (
    <div className="lead-message">
      <span className="lead-byline"><Avatar kind="lead" size={22} /><b>Lead</b><span className="time">· {clockTime(message.createdAt)}</span></span>
      <p className="lead-text">{message.text}</p>
    </div>
  )
}

const SPEC_STATUS: Record<string, [string, string]> = {
  open: ['Needs approval', 'need'], starting: ['Starting', 'build'], started: ['Approved', 'done'], applied: ['Approved', 'done'], dismissed: ['Replaced', 'idle'],
}

function SpecCard({ message, criteria, version }: { message: LeadMessage; criteria: number; version: number }) {
  const run = useApp((state) => state.run)
  const session = useApp((state) => state.session)
  const [text, setText] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [label, tone] = SPEC_STATUS[message.status ?? 'open'] ?? SPEC_STATUS.open
  const toggle = async () => {
    if (text !== null) {
      setText(null)
      return
    }
    try {
      const data = await session!.connection.readFile('specDraft', `${message.projectId}/${message.taskId}`)
      setText(new TextDecoder().decode(data).replace(/^---\n[\s\S]*?\n---\n/, '').trim())
    } catch (error) {
      useApp.getState().showNotice(`Couldn’t open the spec: ${(error as Error).message}`)
    }
  }
  const approve = async () => {
    setBusy(true)
    await run((commands) => commands.approveSpec(message.taskId), 'Couldn’t approve the spec')
    setBusy(false)
  }
  return (
    <section className="card" aria-label={`Spec ${message.title ?? ''}`}>
      <span className="card-title">
        <span>Spec · {message.title ?? 'Untitled'}</span>
        <span className={`pill bg-${tone} tone-${tone}`}>{label}</span>
      </span>
      <div className="kv"><span>Version</span><span>v{version}</span></div>
      <div className="kv"><span>Done when</span><span>{criteria} acceptance criteri{criteria === 1 ? 'on' : 'a'}</span></div>
      {text !== null && <pre className="spec-text">{text}</pre>}
      <div className="card-actions">
        {message.status === 'open' && (
          <button type="button" className="button primary" disabled={busy} onClick={approve}>Approve & start</button>
        )}
        <button type="button" className="button" aria-expanded={text !== null} onClick={toggle}>{text !== null ? 'Hide spec' : 'Read spec'}</button>
      </div>
      {message.status === 'open' && <p className="muted-text">To change it, tell the Lead what to change below.</p>}
    </section>
  )
}

function ProposalCard({ message }: { message: LeadMessage }) {
  const [label, tone] = SPEC_STATUS[message.status ?? 'open'] ?? SPEC_STATUS.open
  return (
    <section className="card" aria-label={`Proposal ${message.title ?? ''}`}>
      <span className="card-title"><span>{message.title ?? 'Proposed run'}</span><span className={`pill bg-${tone} tone-${tone}`}>{label}</span></span>
      {message.workflow && <div className="kv"><span>Workflow</span><span>{workflowTitle(message.workflow)}</span></div>}
      <p className="lead-text">{message.text}</p>
      {message.status === 'open' && <p className="muted-text">Answer the Lead below to start or change it.</p>}
    </section>
  )
}

const PERMISSION_STATUS: Record<string, [string, string]> = {
  pending: ['Needs you', 'need'], allowed: ['Allowed', 'done'], allowedOnce: ['Allowed once', 'done'], allowedForRun: ['Allowed for run', 'done'], denied: ['Denied', 'stuck'],
}

function PermissionCard({ message }: { message: LeadMessage }) {
  const run = useApp((state) => state.run)
  const [busy, setBusy] = useState(false)
  const status = message.permissionStatus ?? 'pending'
  const [label, tone] = PERMISSION_STATUS[status] ?? PERMISSION_STATUS.pending
  const answer = async (decision: 'allow' | 'deny') => {
    if (message.permissionRequestId === null) return
    setBusy(true)
    await run((commands) => commands.answerPermission(decision, { permissionRequestID: message.permissionRequestId! }), 'Couldn’t answer the permission request')
    setBusy(false)
  }
  return (
    <section className="card" aria-label="Permission request">
      <span className="card-title"><span>Permission · {message.capability ?? 'access'}</span><span className={`pill bg-${tone} tone-${tone}`}>{label}</span></span>
      <p className="lead-text">{message.text}</p>
      {status === 'pending' && (
        <div className="card-actions">
          <button type="button" className="button primary" disabled={busy} onClick={() => answer('allow')}>Allow</button>
          <button type="button" className="button" disabled={busy} onClick={() => answer('deny')}>Deny</button>
        </div>
      )}
    </section>
  )
}

function QuestionCard({ request }: { request: ChatRequest }) {
  const run = useApp((state) => state.run)
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const open = request.status === 'open'
  const answer = async (value: string) => {
    if (!value.trim()) return
    setBusy(true)
    const done = await run(async (commands) => {
      await commands.answerQuestion(request.id, value.trim())
      return true
    }, 'Couldn’t send the answer')
    if (done) setText('')
    setBusy(false)
  }
  const questions = request.questions.length > 0 ? request.questions : [{ question: request.body || request.title, options: [] }]
  return (
    <section className={`card ${open ? 'bg-need' : ''}`} aria-label="Question from the Lead">
      <span className="card-title"><span>{request.title}</span>{open && <span className="pill bg-need tone-need">Needs you</span>}</span>
      {questions.map((question, index) => (
        <div key={index} className="section">
          <p className="question-text">{question.question}</p>
          {open && question.options.length > 0 && (
            <div className="options">
              {question.options.map((option) => (
                <button key={option} type="button" className="button small" disabled={busy}
                  onClick={() => answer(questions.length > 1 ? `${question.question}\n${option}` : option)}>{option}</button>
              ))}
            </div>
          )}
        </div>
      ))}
      {open ? (
        <form className="answer-field" onSubmit={(event) => { event.preventDefault(); void answer(text) }}>
          <label className="sr-only" htmlFor={`answer-${request.id}`}>Your answer</label>
          <textarea id={`answer-${request.id}`} rows={1} placeholder="Your answer" value={text} onChange={(event) => setText(event.target.value)} />
          <button type="submit" className="send-button" aria-label="Send answer" disabled={busy || !text.trim()}><Icon name="send" stroke={2.2} /></button>
        </form>
      ) : (
        request.response && <span className="answered">You answered: {request.response}</span>
      )}
    </section>
  )
}

function ApprovalCard({ request }: { request: ChatRequest }) {
  const run = useApp((state) => state.run)
  const [busy, setBusy] = useState(false)
  const open = request.status === 'open' && request.runId !== null
  const resolve = async (approved: boolean) => {
    setBusy(true)
    await run((commands) => commands.resolveApproval(request.runId!, approved, undefined, request.id), 'Couldn’t answer the approval')
    setBusy(false)
  }
  return (
    <section className={`card ${open ? 'bg-need' : ''}`} aria-label="Approval">
      <span className="card-title"><span>{request.title}</span><span className={`pill ${open ? 'bg-need tone-need' : 'bg-idle tone-idle'}`}>{open ? 'Needs you' : 'Answered'}</span></span>
      {request.body && <p className="lead-text">{request.body}</p>}
      {open && (
        <div className="card-actions">
          <button type="button" className="button primary" disabled={busy} onClick={() => resolve(true)}>Approve</button>
          <button type="button" className="button" disabled={busy} onClick={() => resolve(false)}>Reject</button>
        </div>
      )}
    </section>
  )
}

function ProblemCard({ request }: { request: ChatRequest }) {
  const open = request.status === 'open'
  return (
    <section className={`card ${open ? 'bg-stuck' : ''}`} aria-label="Problem">
      <span className="card-title"><span>{request.title}</span>{open && <span className="pill bg-stuck tone-stuck">Stuck</span>}</span>
      {request.body && <p className="lead-text">{request.body}</p>}
      {open && <p className="muted-text">Tell the Lead how to continue, or retry it from the Mac.</p>}
    </section>
  )
}

function EventRows({ events }: { events: RunEvent[] }) {
  const state = useApp()
  return (
    <div className="events">
      {events.map((event) => (
        <button key={event.id} type="button" className="event-row hover" onClick={() => { state.setDetailsTab('log'); state.setDrawer('right') }}>
          <Avatar kind={event.kind} name={event.agent?.name} size={26} busy={event.tone === 'build'} />
          <span className="body">
            <span className="title">{event.title}</span>
            <span className={`sub tone-${event.tone}`}>{event.detail}</span>
          </span>
          <Icon name="chevronRight" size={16} stroke={2} />
        </button>
      ))}
    </div>
  )
}

export function DiffCounts({ added, deleted }: { added: number; deleted: number }) {
  return (
    <span className="mono" aria-label={`${added} lines added, ${deleted} removed`}>
      <span className="tone-done">+{added}</span> <span className="tone-danger">−{deleted}</span>
    </span>
  )
}

function ReviewCard({ summary }: { summary: ChatSummary }) {
  const state = useApp()
  const records = selectRecords(state)
  const review = reviewReady(records, summary)!
  const diff = state.diffs[review.run.id]
  useEffect(() => state.loadDiff(review.run.id), [review.run.id])
  const checks = chatChecks(review.run, records.steps, summary.hold, summary.workers.length > 0)
  const files = diff?.status === 'ready' ? diff.diff.paths.length : review.run.filesChanged ?? 0
  const passed = checks.state.kind === 'passed'
  return (
    <section className="review-card" aria-label="Ready for your review">
      <span className="eyebrow"><span aria-hidden="true" />Ready for your review</span>
      <span className="summary">{review.summary ?? review.run.title}</span>
      <span className="facts">
        {diff?.status === 'ready' && <DiffCounts added={diff.diff.added} deleted={diff.diff.deleted} />}
        {diff?.status === 'ready' && '·'}
        <span>{plural(files, 'file')}</span>
        {checks.rows.length > 0 && <>· <span className={passed ? 'tone-done' : 'tone-stuck'}>checks {checks.rows.filter((row) => row.status === 'passed').length}/{checks.rows.length} {passed ? '✓' : '✕'}</span></>}
        {checks.rows.length === 0 && checks.state.kind !== 'waitingForWorkers' && <>· <span>{checksLabel(checks)}</span></>}
      </span>
      <div className="actions">
        <button type="button" className="button primary grow" onClick={() => state.setReviewing(true)}>Review changes</button>
      </div>
    </section>
  )
}

const IMAGE_TYPES = ['image/png', 'image/jpeg', 'image/gif', 'image/webp']

function Composer({ summary, onComposed }: { summary: ChatSummary | null; onComposed: () => void }) {
  const state = useApp()
  const [text, setText] = useState('')
  const [attachments, setAttachments] = useState<ChatAttachment[]>([])
  const [busy, setBusy] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  const records = selectRecords(state)
  const projectID = summary?.project.id ?? state.projectFilter ?? records.projects.find((project) => project.isOpen)?.id ?? null
  const canSend = (text.trim().length > 0 || attachments.length > 0) && !busy && projectID !== null

  const send = async () => {
    if (!canSend) return
    setBusy(true)
    const message = text.trim()
    const ok = await state.run(async (commands) => {
      if (summary) {
        await commands.sendChat(summary.chat.id, message, attachments)
      } else {
        const chat = await state.session!.connection.send<{ id: number }>('chat.create', { projectID, text: message, attachments })
        if (chat?.id) state.openChat(chat.id)
        onComposed()
      }
      return true
    }, 'Couldn’t send the message')
    if (ok) {
      setText('')
      setAttachments([])
    }
    setBusy(false)
  }

  const attach = async (files: FileList | null) => {
    for (const file of Array.from(files ?? [])) {
      if (!IMAGE_TYPES.includes(file.type) || file.size > 5 * 1024 * 1024) {
        state.showNotice(`Couldn’t attach ${file.name}: use a PNG, JPEG, GIF or WebP image under 5 MB.`)
        continue
      }
      const data = toBase64(new Uint8Array(await file.arrayBuffer()))
      setAttachments((current) => [...current, { image: { id: newUUID(), mediaType: file.type, fileName: file.name, data } }])
    }
  }

  const chat = summary?.chat
  return (
    <div className="composer">
      <div className="composer-inner">
        <form className="composer-box" onSubmit={(event) => { event.preventDefault(); void send() }}>
          <IconButton label="Attach an image" icon="attach" onClick={() => fileInput.current?.click()} />
          <input ref={fileInput} type="file" accept={IMAGE_TYPES.join(',')} multiple hidden onChange={(event) => { void attach(event.target.files); event.target.value = '' }} />
          <div style={{ flex: 1, minWidth: 0 }}>
            {attachments.length > 0 && (
              <div className="attachments">
                {attachments.map((attachment) => 'image' in attachment && (
                  <span key={attachment.image.id} className="attachment">
                    <span>{attachment.image.fileName}</span>
                    <button type="button" aria-label={`Remove ${attachment.image.fileName}`} onClick={() => setAttachments((current) => current.filter((item) => item !== attachment))}>
                      <Icon name="close" size={14} />
                    </button>
                  </span>
                ))}
              </div>
            )}
            <label>
              <span className="sr-only">Message the Lead</span>
              <textarea rows={1} placeholder="Message the Lead" value={text}
                onChange={(event) => {
                  setText(event.target.value)
                  event.target.style.height = 'auto'
                  event.target.style.height = `${Math.min(event.target.scrollHeight, 160)}px`
                }}
                onKeyDown={(event) => {
                  if (event.key === 'Enter' && !event.shiftKey && !('ontouchstart' in window)) {
                    event.preventDefault()
                    void send()
                  }
                }} />
            </label>
          </div>
          <button type="submit" className="send-button" aria-label="Send" disabled={!canSend}><Icon name="send" stroke={2.2} /></button>
        </form>
        <div className="composer-meta">
          <span><Icon name="workflow" size={13} />{workflowTitle(chat?.workflow ?? summary?.latestRun?.workflow)}</span>
          <span>{modelTitle(chat?.leadModel)} · {effortTitle(chat?.leadEffort)}</span>
        </div>
      </div>
    </div>
  )
}
