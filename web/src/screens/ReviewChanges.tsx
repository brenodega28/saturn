import { useEffect, useState } from 'react'
import { plural } from '../format'
import { selectCurrent, selectRecords, useApp } from '../store'
import { chatChecks, checksLabel, reviewReady } from '../thread'
import { IconButton } from '../ui'
import { DiffCounts } from './Chat'

export function ReviewChanges() {
  const state = useApp()
  const summary = selectCurrent(state)
  const records = selectRecords(state)
  const run = summary?.latestRun ?? null
  const review = summary ? reviewReady(records, summary) : null
  const [feedback, setFeedback] = useState('')
  const [asking, setAsking] = useState(false)
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    if (run) state.loadDiff(run.id, true)
  }, [run?.id])
  if (!summary || !run) return null
  const diff = state.diffs[run.id]
  const checks = chatChecks(run, records.steps, summary.hold, summary.workers.length > 0)
  const merged = run.mergedAt !== null
  const close = () => state.setReviewing(false)

  const approve = async () => {
    setBusy(true)
    const done = review?.needsApproval
      ? await state.run(async (commands) => { await commands.resolveApproval(run.id, true, undefined, review.requestID ?? undefined); return true }, 'Couldn’t approve the changes')
      : await state.run(async (commands) => { await commands.merge(run.id, 'mergeCommit'); return true }, 'Couldn’t merge the changes')
    setBusy(false)
    if (done) close()
  }

  const requestChanges = async () => {
    const note = feedback.trim()
    if (!note) return
    setBusy(true)
    const done = review?.needsApproval
      ? await state.run(async (commands) => { await commands.resolveApproval(run.id, false, note, review.requestID ?? undefined); return true }, 'Couldn’t send your feedback')
      : await state.run(async (commands) => { await commands.sendChat(summary.chat.id, note); return true }, 'Couldn’t send your feedback')
    setBusy(false)
    if (done) {
      setFeedback('')
      close()
    }
  }

  return (
    <section className="sheet" role="dialog" aria-modal="true" aria-label="Review changes">
      <header className="chat-header">
        <IconButton label="Back to the chat" icon="back" onClick={close} />
        <div className="chat-heading">
          <span className="chat-title-line"><h1 className="chat-title">Review changes</h1></span>
          <span className="chat-subtitle">{run.title || summary.chat.title}</span>
        </div>
        <span style={{ width: 44 }} />
      </header>
      <div className="sheet-body">
        <div className="pane">
          {review?.summary && <p className="summary-text">{review.summary}</p>}
          <section className="section" aria-label="Changed files">
            <h3>
              Changed files
              {diff?.status === 'ready' && <DiffCounts added={diff.diff.added} deleted={diff.diff.deleted} />}
              {diff?.status === 'ready' && <span className="aside">· {plural(diff.diff.paths.length, 'file')}</span>}
            </h3>
            {(!diff || diff.status === 'loading') && <p className="muted-text">Loading changes…</p>}
            {diff?.status === 'error' && (
              <p className="muted-text">Couldn’t load the changes: {diff.message} <button type="button" className="button small" onClick={() => state.loadDiff(run.id, true)}>Retry</button></p>
            )}
            {diff?.status === 'ready' && diff.diff.paths.length === 0 && <p className="muted-text">No changed files.</p>}
            {diff?.status === 'ready' && diff.diff.paths.length > 0 && (
              <ul className="list-card" style={{ listStyle: 'none', margin: 0, padding: 0 }}>
                {diff.diff.paths.map((path) => <li key={path} className="file-row"><span title={path}>{path}</span></li>)}
              </ul>
            )}
            <p className="muted-text">Line-by-line review and pins stay on the Mac.</p>
          </section>
          <section className="section" aria-label="Checks summary">
            <h3>Checks<span className="end">{checksLabel(checks)}</span></h3>
          </section>
        </div>
      </div>
      <div className="sheet-footer">
        {merged ? (
          <p className="muted-text">These changes are merged.</p>
        ) : asking ? (
          <form className="answer-field" onSubmit={(event) => { event.preventDefault(); void requestChanges() }}>
            <label className="sr-only" htmlFor="review-feedback">What should change?</label>
            <textarea id="review-feedback" rows={2} placeholder="What should change?" value={feedback} onChange={(event) => setFeedback(event.target.value)} autoFocus />
            <button type="submit" className="button primary" disabled={busy || !feedback.trim()}>Send</button>
          </form>
        ) : null}
        {!merged && (
          <div className="row">
            <button type="button" className="button grow" aria-pressed={asking} disabled={busy} onClick={() => setAsking(!asking)}>Request changes</button>
            <button type="button" className="button primary grow" disabled={busy} onClick={approve}>{review?.needsApproval ? 'Approve' : 'Approve & merge'}</button>
          </div>
        )}
      </div>
    </section>
  )
}
