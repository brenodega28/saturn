import { useMemo, useState } from 'react'
import type { ChatGroup, ChatSummary } from '../chats'
import { GROUP_TITLES, GROUPS, STAGE_TITLES, STAGE_TONE, filterChats, groupChats, needsAttention } from '../chats'
import { formatCost, hostTitle, shortTime } from '../format'
import { agentKind } from '../records'
import { selectCurrent, selectRecords, selectSummaries, useApp } from '../store'
import { Avatar, Icon, IconButton, ProjectTile } from '../ui'

export function ChatsDrawer({ onNewChat }: { onNewChat: () => void }) {
  const state = useApp()
  const summaries = selectSummaries(state)
  const projects = selectRecords(state).projects.filter((project) => project.isOpen)
  const current = selectCurrent(state)
  const groups = useMemo(() => {
    const open = groupChats(filterChats(summaries.open, state.projectFilter, state.search))
    open.finished = [...open.finished, ...filterChats(summaries.closed, state.projectFilter, state.search)]
    return open
  }, [summaries, state.projectFilter, state.search])
  const [expanded, setExpanded] = useState<Record<ChatGroup, boolean>>({ needsYou: true, inProgress: true, notStarted: true, finished: false })
  const total = GROUPS.reduce((count, group) => count + groups[group].length, 0)
  const searching = state.search.trim().length > 0
  return (
    <nav className="drawer left" aria-label="Chats">
      <div className="drawer-header">
        <h2 className="drawer-title">Chats</h2>
        <IconButton label="New chat" icon="plus" onClick={onNewChat} />
        <IconButton label="Close chats" icon="close" className="muted close-drawer" onClick={() => state.setDrawer('none')} />
      </div>
      <div className="drawer-tools">
        <label className="search">
          <Icon name="search" size={17} />
          <input type="search" placeholder="Search" aria-label="Search chats and projects" value={state.search} onChange={(event) => state.setSearch(event.target.value)} />
        </label>
        {projects.length > 1 && (
          <div className="chips" role="group" aria-label="Filter by project">
            <button type="button" className="chip" aria-pressed={state.projectFilter === null} onClick={() => state.setProjectFilter(null)}>All projects</button>
            {projects.map((project) => (
              <button key={project.id} type="button" className="chip" aria-pressed={state.projectFilter === project.id}
                onClick={() => state.setProjectFilter(state.projectFilter === project.id ? null : project.id)}>
                <ProjectTile name={project.name} />{project.name}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="drawer-body">
        {total === 0 && (
          <p className="drawer-empty">{searching || state.projectFilter !== null ? 'No chats match.' : 'No chats yet. Start one with the + button.'}</p>
        )}
        {GROUPS.map((group) => {
          const items = groups[group]
          const isOpen = expanded[group] || (searching && items.length > 0)
          return (
            <section key={group} aria-label={GROUP_TITLES[group]}>
              <button type="button" className={`group-toggle ${group === 'needsYou' && items.length > 0 ? 'attention' : ''}`} aria-expanded={isOpen}
                onClick={() => setExpanded((current) => ({ ...current, [group]: !isOpen }))}>
                <Icon name="chevronDown" size={13} stroke={2.4} />
                {GROUP_TITLES[group]}<span className="count">{items.length}</span>
              </button>
              {isOpen && (
                <ul className="group-list">
                  {items.map((summary) => (
                    <li key={summary.chat.id}>
                      <ChatRow summary={summary} current={current?.chat.id === summary.chat.id} onOpen={() => state.openChat(summary.chat.id)} />
                    </li>
                  ))}
                </ul>
              )}
            </section>
          )
        })}
      </div>
      <WeekSpend />
    </nav>
  )
}

function ChatRow({ summary, current, onOpen }: { summary: ChatSummary; current: boolean; onOpen: () => void }) {
  const tone = STAGE_TONE[summary.stage]
  const showCrew = summary.stage !== 'finished' && summary.stage !== 'done' && summary.stage !== 'dropped'
  const busy = summary.stage === 'building' || summary.stage === 'inReview'
  const crew = showCrew ? summary.workers.slice(0, 3) : []
  const classes = ['chat-row', 'hover', needsAttention(summary.stage) ? 'attention' : '', summary.isUnread ? 'unread' : ''].join(' ')
  return (
    <button type="button" className={classes} aria-current={current ? 'page' : undefined} onClick={onOpen}
      aria-label={`${summary.chat.title}, ${STAGE_TITLES[summary.stage]}, ${summary.project.name}${summary.isUnread ? ', unread' : ''}`}>
      <span className={`state fill-${tone}`} aria-hidden="true" />
      <span className="body" aria-hidden="true">
        <span className="top">
          <span className="name">{summary.chat.title || 'New chat'}</span>
          <span className="time">{shortTime(summary.lastActivity)}</span>
        </span>
        <span className="meta">
          <ProjectTile name={summary.project.name} />
          <span style={{ flex: 'none' }}>{summary.project.name}</span>
          <span style={{ flex: 'none', color: 'var(--text3)' }}>·</span>
          <span className="host">{hostTitle(summary.project.host)}</span>
          {summary.costUSD > 0 && <span className="mono">{formatCost(summary.costUSD)}</span>}
          {crew.length > 0 && (
            <span className="crew">
              {crew.map((agent) => <span key={agent.id}><Avatar kind={agentKind(agent)} name={agent.name} size={18} busy={busy} /></span>)}
            </span>
          )}
        </span>
      </span>
    </button>
  )
}

function WeekSpend() {
  const state = useApp()
  const records = selectRecords(state)
  const start = new Date()
  start.setHours(0, 0, 0, 0)
  start.setDate(start.getDate() - ((start.getDay() + 6) % 7))
  const spent = records.usage.filter((entry) => entry.recordedAt && entry.recordedAt >= start).reduce((total, entry) => total + entry.costUSD, 0)
  return (
    <div className="drawer-footer">
      <span>{state.daemonName || 'Saturn'}</span>
      <span style={{ marginLeft: 'auto' }}><span className="mono" style={{ color: 'var(--text)' }}>{formatCost(spent)}</span> · wk</span>
    </div>
  )
}
