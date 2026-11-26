#!/usr/bin/env node
// Records what saturnd sends a fresh client: welcome, snapshot, live and changes.
// Usage: node scripts/record-fixture.mjs [--data-dir DIR | --socket PATH] [--out fixtures/recorded.jsonl] [--seconds 10]
import { randomUUID } from 'node:crypto'
import { createWriteStream, mkdirSync } from 'node:fs'
import { connect } from 'node:net'
import { homedir } from 'node:os'
import { dirname, join, resolve } from 'node:path'

function option(name, fallback) {
  const index = process.argv.indexOf(`--${name}`)
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback
}

const dataDir = option('data-dir', join(homedir(), 'Library', 'Application Support', 'Saturn'))
const socketPath = option('socket', join(dataDir, 'saturnd.sock'))
const out = resolve(option('out', 'fixtures/recorded.jsonl'))
const seconds = Number(option('seconds', '10'))

mkdirSync(dirname(out), { recursive: true })
const file = createWriteStream(out)
const socket = connect(socketPath)
let buffer = ''
let lines = 0
let snapshotDone = false

function finish(reason) {
  socket.end(JSON.stringify({ bye: {} }) + '\n')
  file.end(() => {
    console.log(`Recorded ${lines} lines to ${out} (${reason}).`)
    process.exit(0)
  })
}

socket.on('connect', () => {
  const hello = { clientID: randomUUID().toUpperCase(), protocolVersion: 1 }
  socket.write(JSON.stringify({ hello: { _0: hello } }) + '\n')
})

socket.on('data', (chunk) => {
  buffer += chunk.toString('utf8')
  let newline
  while ((newline = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, newline)
    buffer = buffer.slice(newline + 1)
    if (!line.trim()) continue
    file.write(line + '\n')
    lines++
    const kind = Object.keys(JSON.parse(line))[0]
    if (kind === 'refused') finish('the daemon refused the client')
    if (kind === 'snapshotEnd' && !snapshotDone) {
      snapshotDone = true
      console.log(`Snapshot received; recording changes for ${seconds}s…`)
      setTimeout(() => finish('time is up'), seconds * 1000)
    }
  }
})

socket.on('error', (error) => {
  console.error(`Couldn’t talk to saturnd at ${socketPath}: ${error.message}`)
  process.exit(1)
})
socket.on('close', () => finish('the daemon closed the socket'))
