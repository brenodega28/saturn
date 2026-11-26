import { useEffect, useState } from 'react'
import type { SnapshotReader } from './replica'
import { ChatScreen } from './screens/Chat'
import { ChatsDrawer } from './screens/ChatsDrawer'
import { DetailsDrawer } from './screens/DetailsDrawer'
import { Pairing } from './screens/Pairing'
import { ReviewChanges } from './screens/ReviewChanges'
import { selectSummaries, useApp } from './store'
import { AvatarDefs, Dots } from './ui'

export interface AppProps {
  socketURL: (token: string) => string
  readSnapshot: SnapshotReader
  socket?: (url: string) => WebSocket
  delays?: number[]
}

function useMedia(query: string): boolean {
  const [matches, setMatches] = useState(() => typeof window.matchMedia === 'function' && window.matchMedia(query).matches)
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const media = window.matchMedia(query)
    const update = () => setMatches(media.matches)
    media.addEventListener?.('change', update)
    return () => media.removeEventListener?.('change', update)
  }, [query])
  return matches
}

export function App({ socketURL, readSnapshot, socket, delays }: AppProps) {
  const token = useApp((state) => state.token)
  const status = useApp((state) => state.status)
  const statusDetail = useApp((state) => state.statusDetail)
  const setToken = useApp((state) => state.setToken)
  const [revoked, setRevoked] = useState(false)

  useEffect(() => {
    if (!token) return
    useApp.getState().connect({ url: socketURL(token), token, readSnapshot, socket, delays })
    const online = () => useApp.getState().session?.connection.reconnectNow()
    window.addEventListener('online', online)
    return () => {
      window.removeEventListener('online', online)
      useApp.getState().disconnect()
    }
  }, [token])

  useEffect(() => {
    if (status === 'unauthorized') setRevoked(true)
  }, [status])

  if (!token) {
    return <Pairing onPaired={(value) => { setRevoked(false); setToken(value) }}
      reason={revoked ? 'This device isn’t paired any more. Pair it again from Saturn › Settings › Remote access on your Mac.' : undefined} />
  }
  if (status === 'refused') {
    return <main className="pairing"><form><h1>Can’t connect</h1><p>{statusDetail}</p></form></main>
  }
  return <Workspace />
}

function Workspace() {
  const state = useApp()
  const ready = state.session?.replica.isReady || state.version > 0
  const dockLeft = useMedia('(min-width: 900px)')
  const dockRight = useMedia('(min-width: 1280px)')
  const summaries = selectSummaries(state)
  const empty = summaries.open.length === 0 && summaries.closed.length === 0

  useEffect(() => {
    const close = (event: KeyboardEvent) => {
      if (event.key !== 'Escape') return
      if (state.reviewing) state.setReviewing(false)
      else state.setDrawer('none')
    }
    window.addEventListener('keydown', close)
    return () => window.removeEventListener('keydown', close)
  }, [state.reviewing])

  if (!ready) {
    return (
      <div className="app"><AvatarDefs /><p className="loading" role="status">Connecting to Saturn<Dots /></p></div>
    )
  }
  const showLeft = state.drawer === 'left' || dockLeft
  const showRight = state.drawer === 'right' || dockRight
  const scrim = (state.drawer === 'left' && !dockLeft) || (state.drawer === 'right' && !dockRight)
  return (
    <div className={`app ${dockLeft ? 'docked-left' : ''} ${dockRight ? 'docked-right' : ''}`}>
      <AvatarDefs />
      {showLeft && <ChatsDrawer onNewChat={() => state.setComposing(true)} />}
      <ChatScreen composing={state.composing || empty} onComposed={() => state.setComposing(false)} />
      {showRight && <DetailsDrawer />}
      {scrim && <button type="button" className="scrim" aria-label="Close panel" tabIndex={-1} onClick={() => state.setDrawer('none')} />}
      {state.reviewing && <ReviewChanges />}
    </div>
  )
}
