import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import wasmURL from 'sql.js/dist/sql-wasm.wasm?url'
import { registerSW } from 'virtual:pwa-register'
import { App } from './App'
import { socketURL } from './connection'
import { sqliteSnapshotReader } from './sqlite'
import './styles.css'

registerSW({ immediate: true })

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App socketURL={(token) => socketURL(window.location, token)} readSnapshot={sqliteSnapshotReader({ locateFile: () => wasmURL })} />
  </StrictMode>,
)
