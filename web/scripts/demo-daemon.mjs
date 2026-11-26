#!/usr/bin/env node
// A stand-in daemon for trying the client without saturnd: replays fixtures/mobile-v6.jsonl over /ws
// and accepts the pairing code 123456 on POST /pair.
// Usage: node scripts/demo-daemon.mjs [--port 7979], then SATURN_REMOTE_URL=http://127.0.0.1:7979 npm run dev
import { readFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { WebSocketServer } from 'ws'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const portIndex = process.argv.indexOf('--port')
const port = Number(portIndex >= 0 ? process.argv[portIndex + 1] : 7979)
const lines = readFileSync(resolve(root, 'fixtures/mobile-v6.jsonl'), 'utf8').split('\n').filter((line) => line.trim())
const TOKEN = 'demo-token'
const DIFF = { paths: ['src/Hamburger.tsx', 'src/MobileMenu.tsx', 'src/nav.module.css', 'src/nav.spec.ts', 'src/App.tsx', 'src/index.css', 'e2e/menu.spec.ts'], added: 186, deleted: 24 }
const ANSWERS = { 'run.diffSummary': DIFF, 'chat.approveSpec': 1, 'run.push': 'Pushed.' }

const server = createServer((request, response) => {
  if (request.method === 'POST' && request.url === '/pair') {
    let body = ''
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      const { code } = JSON.parse(body || '{}')
      response.writeHead(code === '123456' ? 200 : 401, { 'Content-Type': 'application/json' })
      response.end(code === '123456' ? JSON.stringify({ token: TOKEN, deviceID: '00000000-0000-4000-8000-000000000001' }) : '{}')
    })
    return
  }
  response.writeHead(404)
  response.end()
})

const sockets = new WebSocketServer({ server, path: '/ws' })
sockets.on('connection', (socket, request) => {
  if (new URL(request.url ?? '', 'http://localhost').searchParams.get('token') !== TOKEN) {
    socket.close(4401, 'unauthorized')
    return
  }
  socket.on('message', (data) => {
    const message = JSON.parse(data.toString())
    if (message.hello) {
      for (const line of lines) socket.send(line)
    } else if (message.command) {
      const { id, name } = message.command._0
      const ok = Buffer.from(JSON.stringify(ANSWERS[name] ?? {})).toString('base64')
      socket.send(JSON.stringify({ result: { _0: { id, ok } } }))
    } else if (message.file) {
      const { requestID } = message.file._0
      const text = Buffer.from('## Summary\nCheck that one e2e test covers sign-up to checkout.\n').toString('base64')
      socket.send(JSON.stringify({ fileChunk: { _0: { requestID, offset: 0, data: text, end: true, caughtUp: false } } }))
    }
  })
})

server.listen(port, '127.0.0.1', () => console.log(`Demo daemon on http://127.0.0.1:${port} (pairing code 123456)`))
