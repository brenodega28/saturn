#!/usr/bin/env node
// Builds fixtures/mobile-v6.jsonl: the lines saturnd sends a new client (welcome, snapshot, live),
// with a SQLite snapshot that uses saturnd's schema (Storage/AppDatabase.swift, migrations v1–v29) and made-up rows.
import { writeFileSync, mkdirSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import initSqlJs from 'sql.js'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const out = resolve(root, 'fixtures/mobile-v6.jsonl')

const SCHEMA = `
CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY);
CREATE TABLE "project" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "path" TEXT NOT NULL, "host" TEXT, "isOpen" BOOLEAN NOT NULL DEFAULT 0, "createdAt" DATETIME NOT NULL, "lastOpenedAt" DATETIME NOT NULL, "settings" TEXT NOT NULL DEFAULT '{}');
CREATE TABLE "task" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "title" TEXT NOT NULL, "body" TEXT NOT NULL DEFAULT '', "source" TEXT NOT NULL, "sourceURL" TEXT, "workflow" TEXT, "status" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL, "externalNumber" INTEGER, "repository" TEXT, "labels" TEXT NOT NULL DEFAULT '[]', "closedAt" DATETIME, "closeReason" TEXT, "viewedAt" DATETIME, "leadModel" TEXT, "leadEffort" TEXT, "finishedAt" DATETIME, "isOnboarding" BOOLEAN NOT NULL DEFAULT 0);
CREATE TABLE "run" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "taskId" INTEGER NOT NULL REFERENCES "task"("id") ON DELETE CASCADE, "workflow" TEXT NOT NULL, "workflowVersion" TEXT, "currentStep" TEXT, "status" TEXT NOT NULL, "outcome" TEXT, "costUSD" DOUBLE NOT NULL DEFAULT 0, "startedAt" DATETIME NOT NULL, "endedAt" DATETIME, "title" TEXT NOT NULL DEFAULT '', "workflowSnapshot" TEXT NOT NULL DEFAULT '', "budgetUSD" DOUBLE, "endAction" TEXT, "pullRequestURL" TEXT, "lastError" TEXT, "engineState" TEXT NOT NULL DEFAULT '{}', "brief" TEXT, "deliveryBranch" TEXT, "baseBranch" TEXT, "mergedAt" DATETIME, "linesChanged" INTEGER, "filesChanged" INTEGER, "pushedAt" DATETIME);
CREATE TABLE "agent" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "runId" INTEGER REFERENCES "run"("id") ON DELETE SET NULL, "role" TEXT NOT NULL, "name" TEXT NOT NULL, "step" TEXT, "worktreePath" TEXT, "branch" TEXT, "status" TEXT NOT NULL, "sessionId" TEXT, "inputTokens" INTEGER NOT NULL DEFAULT 0, "outputTokens" INTEGER NOT NULL DEFAULT 0, "costUSD" DOUBLE NOT NULL DEFAULT 0, "isPinned" BOOLEAN NOT NULL DEFAULT 0, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL, "model" TEXT NOT NULL DEFAULT 'sonnet', "task" TEXT NOT NULL DEFAULT '', "baseBranch" TEXT, "cacheReadTokens" INTEGER NOT NULL DEFAULT 0, "cacheWriteTokens" INTEGER NOT NULL DEFAULT 0, "processID" INTEGER, "lastError" TEXT, "runStepId" INTEGER REFERENCES "runStep"("id") ON DELETE SET NULL, "readOnly" BOOLEAN NOT NULL DEFAULT 0, "planTaskId" TEXT, "port" INTEGER, "archivedAt" DATETIME, "taskId" INTEGER REFERENCES "task"("id") ON DELETE SET NULL, "spawnedById" INTEGER, "sessionCostUSD" DOUBLE NOT NULL DEFAULT 0, "sessionOutputTokens" INTEGER NOT NULL DEFAULT 0, "skills" TEXT NOT NULL DEFAULT '[]', UNIQUE ("projectId", "name"));
CREATE TABLE "usage" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "runId" INTEGER REFERENCES "run"("id") ON DELETE SET NULL, "agentId" INTEGER REFERENCES "agent"("id") ON DELETE SET NULL, "model" TEXT NOT NULL, "inputTokens" INTEGER NOT NULL DEFAULT 0, "outputTokens" INTEGER NOT NULL DEFAULT 0, "cacheReadTokens" INTEGER NOT NULL DEFAULT 0, "cacheWriteTokens" INTEGER NOT NULL DEFAULT 0, "costUSD" DOUBLE NOT NULL, "recordedAt" DATETIME NOT NULL);
CREATE TABLE "runStep" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "runId" INTEGER NOT NULL REFERENCES "run"("id") ON DELETE CASCADE, "stepId" TEXT NOT NULL, "iteration" INTEGER NOT NULL DEFAULT 1, "status" TEXT NOT NULL, "outcome" TEXT, "output" TEXT, "input" TEXT, "costUSD" DOUBLE NOT NULL DEFAULT 0, "startedAt" DATETIME NOT NULL, "endedAt" DATETIME);
CREATE TABLE "pin" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "runId" INTEGER NOT NULL REFERENCES "run"("id") ON DELETE CASCADE, "agentId" INTEGER REFERENCES "agent"("id") ON DELETE SET NULL, "file" TEXT NOT NULL, "startLine" INTEGER NOT NULL, "endLine" INTEGER NOT NULL, "title" TEXT NOT NULL, "tags" TEXT NOT NULL DEFAULT '[]', "explanation" TEXT NOT NULL, "status" TEXT NOT NULL, "response" TEXT, "createdAt" DATETIME NOT NULL, "updatedAt" DATETIME NOT NULL, "side" TEXT NOT NULL DEFAULT 'new', "byUser" BOOLEAN NOT NULL DEFAULT 0, "confidence" DOUBLE, "category" TEXT);
CREATE TABLE "reviewViewedFile" ("runId" INTEGER NOT NULL REFERENCES "run"("id") ON DELETE CASCADE, "path" TEXT NOT NULL, "fingerprint" TEXT NOT NULL, "viewedAt" DATETIME NOT NULL, PRIMARY KEY ("runId", "path"));
CREATE TABLE "leadMessage" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "taskId" INTEGER NOT NULL REFERENCES "task"("id") ON DELETE CASCADE, "kind" TEXT NOT NULL, "text" TEXT NOT NULL DEFAULT '', "workflow" TEXT, "title" TEXT, "status" TEXT, "runId" INTEGER REFERENCES "run"("id") ON DELETE SET NULL, "createdAt" DATETIME NOT NULL, "attachments" TEXT, "permissionRequestId" INTEGER, "permissionStatus" TEXT, "capability" TEXT);
CREATE TABLE "evidence" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "runId" INTEGER NOT NULL REFERENCES "run"("id") ON DELETE CASCADE, "agentId" INTEGER, "kind" TEXT NOT NULL, "title" TEXT NOT NULL, "file" TEXT NOT NULL, "note" TEXT NOT NULL, "createdAt" DATETIME NOT NULL);
CREATE TABLE "correction" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "runId" INTEGER, "pinId" INTEGER, "file" TEXT, "text" TEXT NOT NULL, "createdAt" DATETIME NOT NULL, "encodedAt" DATETIME, "encoding" TEXT);
CREATE TABLE "permissionRequest" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "agentId" INTEGER NOT NULL, "capability" TEXT NOT NULL, "request" TEXT NOT NULL, "status" TEXT NOT NULL, "requestId" INTEGER, "createdAt" DATETIME NOT NULL, "answeredAt" DATETIME, "scope" TEXT NOT NULL DEFAULT 'once', "runId" INTEGER, "consumedAt" DATETIME, "taskId" INTEGER, "rules" TEXT NOT NULL DEFAULT '[]');
CREATE TABLE "chatRequest" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "projectId" INTEGER NOT NULL REFERENCES "project"("id") ON DELETE CASCADE, "taskId" INTEGER NOT NULL REFERENCES "task"("id") ON DELETE CASCADE, "runId" INTEGER REFERENCES "run"("id") ON DELETE CASCADE, "agentId" INTEGER REFERENCES "agent"("id") ON DELETE SET NULL, "kind" TEXT NOT NULL, "title" TEXT NOT NULL, "body" TEXT NOT NULL DEFAULT '', "status" TEXT NOT NULL, "response" TEXT, "questions" TEXT, "createdAt" DATETIME NOT NULL, "resolvedAt" DATETIME);
CREATE TABLE "changeLog" ("seq" INTEGER PRIMARY KEY AUTOINCREMENT, "tableName" TEXT NOT NULL, "op" TEXT NOT NULL, "rowID" INTEGER NOT NULL, "row" TEXT);
`

const DAY = '2026-11-25'
const at = (time, day = DAY) => `${day} ${time}.000`

const WORKFLOW = `name: Feature delivery
version: 1
steps:
  - id: build
    type: agent
    agent: builder
    title: Build
  - id: checks
    type: check
    title: Checks
    max_rounds: 3
  - id: review
    type: agent
    agent: checker
    title: Review
  - id: approve
    type: approval
    title: Your approval
end: {}
`

const checkResult = (name, durationSeconds) => ({ name, kind: 'test', command: name.toLowerCase(), status: 'passed', durationSeconds, output: '' })
const CHECKS = JSON.stringify({
  taskResults: [], branchHeads: {},
  checks: [{ agentName: 'Front-end Dev', round: 1, notes: [], results: [
    checkResult('Typecheck', 8), checkResult('Lint', 4), checkResult('Unit tests', 21), checkResult('E2E · mobile', 72), checkResult('Accessibility', 9),
  ] }],
})
const REVIEW_SUMMARY = 'The menu opens from a 3-bar icon that folds into an X. Focus is trapped while it’s open and Esc closes it.'

const rows = {
  project: [
    { id: 1, name: 'monorepo', path: '/Users/dev/code/monorepo', host: null, isOpen: 1, createdAt: at('09:00:00', '2026-11-01'), lastOpenedAt: at('09:00:00'), settings: '{"runCommand":"make dev"}' },
    { id: 2, name: 'ensemble', path: '/home/dev/ensemble', host: 'dev@buildbox', isOpen: 1, createdAt: at('09:00:00', '2026-11-01'), lastOpenedAt: at('09:00:00'), settings: '{}' },
    { id: 3, name: 'perigee', path: '/Users/dev/code/perigee', host: null, isOpen: 1, createdAt: at('09:00:00', '2026-11-01'), lastOpenedAt: at('09:00:00'), settings: '{}' },
  ],
  task: [
    { id: 1, projectId: 1, title: 'Rate-limit the public API before the launch', source: 'chat', status: 'waitingOnYou', createdAt: at('13:30:00'), updatedAt: at('13:40:00'), viewedAt: at('13:31:00'), leadModel: 'opus', leadEffort: 'high' },
    { id: 2, projectId: 3, title: 'Let’s work on phase 1', source: 'chat', status: 'failed', createdAt: at('10:00:00', '2026-11-01'), updatedAt: at('11:00:00', '2026-11-01') },
    { id: 3, projectId: 1, title: 'Hamburger menu for mobile', source: 'chat', workflow: 'feature-delivery', status: 'waitingOnYou', createdAt: at('13:43:00'), updatedAt: at('14:22:00'), viewedAt: at('14:22:00'), leadModel: 'opus', leadEffort: 'medium' },
    { id: 4, projectId: 2, title: 'Check the deploy script on the build box', source: 'chat', status: 'running', createdAt: at('13:20:00'), updatedAt: at('13:32:00') },
    { id: 5, projectId: 1, title: 'Verify if there’s an e2e test for the complete flow', source: 'chat', status: 'incoming', createdAt: at('16:00:00', '2026-11-24'), updatedAt: at('16:05:00', '2026-11-24'), viewedAt: at('16:10:00', '2026-11-24') },
    { id: 6, projectId: 2, title: 'Analyze t3code and list what we could borrow', source: 'chat', status: 'incoming', createdAt: at('10:00:00', '2026-11-22'), updatedAt: at('10:00:00', '2026-11-22'), viewedAt: at('11:00:00', '2026-11-22') },
    { id: 7, projectId: 1, title: 'Given the new pricing table, update the checkout copy', source: 'chat', status: 'done', createdAt: at('09:00:00', '2026-11-24'), updatedAt: at('12:00:00', '2026-11-24'), finishedAt: at('12:00:00', '2026-11-24'), viewedAt: at('12:30:00', '2026-11-24') },
    { id: 8, projectId: 3, title: 'Try a WebGL renderer', source: 'chat', status: 'dismissed', createdAt: at('09:00:00', '2026-11-20'), updatedAt: at('09:30:00', '2026-11-20'), closedAt: at('09:30:00', '2026-11-20'), closeReason: 'dropped' },
    { id: 9, projectId: 3, title: 'Add a CHANGELOG entry for 2.4', source: 'chat', status: 'waitingOnYou', createdAt: at('12:00:00'), updatedAt: at('12:05:00') },
  ],
  run: [
    { id: 2, projectId: 3, taskId: 2, workflow: 'feature-delivery', currentStep: 'build', status: 'failed', costUSD: 7.8, startedAt: at('10:10:00', '2026-11-01'), endedAt: at('11:00:00', '2026-11-01'), title: 'Phase 1', workflowSnapshot: WORKFLOW, lastError: 'The build step failed twice.', engineState: '{}' },
    { id: 3, projectId: 1, taskId: 3, workflow: 'feature-delivery', currentStep: 'approve', status: 'waitingOnYou', costUSD: 4.15, startedAt: at('13:44:00'), title: 'Hamburger menu for mobile', workflowSnapshot: WORKFLOW,
      engineState: JSON.stringify({ hold: { reason: 'approval', stepId: 'approve', requestId: 31, message: 'Approve the hamburger menu' }, loopCounts: {}, extraLoops: {}, reviewNotes: [] }),
      deliveryBranch: 'saturn/hamburger-menu', baseBranch: 'main', linesChanged: 210, filesChanged: 7 },
    { id: 4, projectId: 2, taskId: 4, workflow: 'feature-delivery', currentStep: 'build', status: 'running', costUSD: 0.62, startedAt: at('13:25:00'), title: 'Check the deploy script', workflowSnapshot: WORKFLOW, engineState: '{}' },
    { id: 7, projectId: 1, taskId: 7, workflow: 'feature-delivery', currentStep: null, status: 'succeeded', costUSD: 6.4, startedAt: at('09:10:00', '2026-11-24'), endedAt: at('11:50:00', '2026-11-24'), title: 'Checkout copy', workflowSnapshot: WORKFLOW, engineState: '{}', deliveryBranch: 'saturn/checkout-copy', baseBranch: 'main', mergedAt: at('11:55:00', '2026-11-24'), linesChanged: 40, filesChanged: 3 },
  ],
  runStep: [
    { id: 20, runId: 2, stepId: 'build', iteration: 1, status: 'failed', outcome: null, output: '{"summary":"The migration script couldn’t reach the database."}', startedAt: at('10:10:00', '2026-11-01'), endedAt: at('11:00:00', '2026-11-01') },
    { id: 30, runId: 3, stepId: 'build', iteration: 1, status: 'succeeded', outcome: 'done', output: '{"summary":"Built the menu and the focus trap","taskResults":[],"branchHeads":{},"checks":[]}', startedAt: at('13:45:00'), endedAt: at('14:03:00') },
    { id: 31, runId: 3, stepId: 'checks', iteration: 1, status: 'succeeded', outcome: 'passed', output: CHECKS, startedAt: at('14:03:00'), endedAt: at('14:05:00') },
    { id: 32, runId: 3, stepId: 'review', iteration: 1, status: 'succeeded', outcome: 'approved', output: JSON.stringify({ summary: REVIEW_SUMMARY }), startedAt: at('14:05:00'), endedAt: at('14:22:00') },
    { id: 40, runId: 4, stepId: 'build', iteration: 1, status: 'running', startedAt: at('13:26:00') },
    { id: 70, runId: 7, stepId: 'build', iteration: 1, status: 'succeeded', outcome: 'done', output: '{"summary":"Updated the checkout copy"}', startedAt: at('09:10:00', '2026-11-24'), endedAt: at('11:00:00', '2026-11-24') },
  ],
  agent: [
    { id: 1, projectId: 1, role: 'lead', name: 'Lead', status: 'idle', model: 'opus', taskId: 1, createdAt: at('13:30:00'), updatedAt: at('13:40:00') },
    { id: 2, projectId: 3, role: 'lead', name: 'Lead 2', status: 'idle', model: 'opus', taskId: 2, createdAt: at('10:00:00', '2026-11-01'), updatedAt: at('10:00:00', '2026-11-01') },
    { id: 3, projectId: 1, role: 'lead', name: 'Lead 3', status: 'idle', model: 'opus', taskId: 3, createdAt: at('13:43:00'), updatedAt: at('14:22:00') },
    { id: 4, projectId: 2, role: 'lead', name: 'Lead 4', status: 'idle', model: 'opus', taskId: 4, createdAt: at('13:20:00'), updatedAt: at('13:20:00') },
    { id: 10, projectId: 3, runId: 2, runStepId: 20, role: 'builder', name: 'Django Dev', status: 'failed', model: 'sonnet', task: 'Write the phase 1 migrations', branch: 'saturn/phase-1', baseBranch: 'main', createdAt: at('10:10:00', '2026-11-01'), updatedAt: at('11:00:00', '2026-11-01') },
    { id: 11, projectId: 1, runId: 3, runStepId: 30, role: 'builder', name: 'Front-end Dev', status: 'idle', model: 'sonnet', task: 'Built the menu and the focus trap', branch: 'saturn/hamburger-menu', baseBranch: 'main', createdAt: at('13:45:00'), updatedAt: at('14:03:00') },
    { id: 12, projectId: 1, runId: 3, runStepId: 32, role: 'checker', name: 'Reviewer', status: 'idle', model: 'opus', task: 'Review MobileMenu.tsx', createdAt: at('14:05:00'), updatedAt: at('14:22:00') },
    { id: 13, projectId: 2, runId: 4, runStepId: 40, role: 'builder', name: 'Claude Code', status: 'working', model: 'sonnet', task: 'Read the deploy script and list what breaks', branch: 'saturn/deploy-check', baseBranch: 'main', createdAt: at('13:26:00'), updatedAt: at('13:32:00') },
    { id: 14, projectId: 1, runId: 7, role: 'builder', name: 'Copy Writer', status: 'idle', model: 'sonnet', task: 'Update the checkout copy', archivedAt: at('12:00:00', '2026-11-24'), createdAt: at('09:10:00', '2026-11-24'), updatedAt: at('12:00:00', '2026-11-24') },
    { id: 15, projectId: 3, role: 'lead', name: 'Lead 9', status: 'idle', model: 'opus', taskId: 9, createdAt: at('12:00:00'), updatedAt: at('12:00:00') },
  ],
  leadMessage: [
    { id: 1, projectId: 1, taskId: 1, kind: 'user', text: 'Rate-limit the public API before the launch', createdAt: at('13:30:00') },
    { id: 2, projectId: 1, taskId: 1, kind: 'lead', text: 'I need one decision before I write the spec.', createdAt: at('13:40:00') },
    { id: 10, projectId: 1, taskId: 3, kind: 'user', text: 'In mobile, create a hamburger icon with animation that opens a menu', createdAt: at('13:43:00') },
    { id: 11, projectId: 1, taskId: 3, kind: 'lead', text: 'One task for Front-end Dev, then a review. You approved the spec.', createdAt: at('13:44:00') },
    { id: 12, projectId: 1, taskId: 3, kind: 'specDraft', title: 'Hamburger menu', status: 'started', text: '{"criteria":3,"version":1}', createdAt: at('13:43:30') },
    { id: 20, projectId: 2, taskId: 4, kind: 'user', text: 'Check the deploy script on the build box', createdAt: at('13:20:00') },
    { id: 21, projectId: 2, taskId: 4, kind: 'lead', text: 'Starting Claude Code on it now.', createdAt: at('13:24:00') },
    { id: 30, projectId: 1, taskId: 5, kind: 'user', text: 'Verify if there’s an e2e test for the complete flow', createdAt: at('16:00:00', '2026-11-24') },
    { id: 31, projectId: 1, taskId: 5, kind: 'specDraft', title: 'E2E coverage check', status: 'open', text: '{"criteria":4,"version":2}', createdAt: at('16:05:00', '2026-11-24') },
    { id: 40, projectId: 2, taskId: 6, kind: 'user', text: 'Analyze t3code and list what we could borrow', createdAt: at('10:00:00', '2026-11-22') },
    { id: 50, projectId: 1, taskId: 7, kind: 'user', text: 'Given the new pricing table, update the checkout copy', createdAt: at('09:00:00', '2026-11-24') },
    { id: 51, projectId: 1, taskId: 7, kind: 'lead', text: 'Done and merged into main.', createdAt: at('12:00:00', '2026-11-24') },
    { id: 60, projectId: 3, taskId: 8, kind: 'user', text: 'Try a WebGL renderer', createdAt: at('09:00:00', '2026-11-20') },
    { id: 70, projectId: 3, taskId: 9, kind: 'user', text: 'Add a CHANGELOG entry for 2.4', createdAt: at('12:00:00') },
    { id: 71, projectId: 3, taskId: 9, kind: 'permission', text: 'Lead wants to run git log --oneline -20 in perigee.', capability: 'shell', permissionRequestId: 5, permissionStatus: 'pending', createdAt: at('12:05:00') },
    { id: 80, projectId: 3, taskId: 2, kind: 'user', text: 'Let’s work on phase 1', createdAt: at('10:00:00', '2026-11-01') },
  ],
  chatRequest: [
    { id: 11, projectId: 1, taskId: 1, agentId: 1, kind: 'question', title: 'How strict should the limit be?', body: '', status: 'open',
      questions: JSON.stringify([{ question: 'Which limit should anonymous clients get?', options: ['60 per minute', '600 per hour'] }]), createdAt: at('13:40:00') },
    { id: 31, projectId: 1, taskId: 3, runId: 3, kind: 'approval', title: 'Approve the hamburger menu', body: REVIEW_SUMMARY, status: 'open', createdAt: at('14:22:00') },
  ],
  permissionRequest: [
    { id: 5, projectId: 3, agentId: 15, capability: 'shell', request: '{}', status: 'pending', createdAt: at('12:05:00'), taskId: 9 },
  ],
  usage: [
    { id: 1, projectId: 1, agentId: 1, model: 'opus', costUSD: 1.2, recordedAt: at('13:40:00') },
    { id: 2, projectId: 3, runId: 2, model: 'sonnet', costUSD: 7.8, recordedAt: at('11:00:00', '2026-11-01') },
    { id: 3, projectId: 1, runId: 3, model: 'sonnet', costUSD: 4.15, recordedAt: at('14:22:00') },
    { id: 4, projectId: 2, runId: 4, model: 'sonnet', costUSD: 0.62, recordedAt: at('13:32:00') },
    { id: 5, projectId: 1, runId: 7, model: 'sonnet', costUSD: 6.4, recordedAt: at('11:50:00', '2026-11-24') },
  ],
}

const SQL = await initSqlJs()
const db = new SQL.Database()
db.run(SCHEMA)
for (const identifier of ['v1', 'v29-onboarding-chat']) db.run('INSERT INTO grdb_migrations VALUES (?)', [identifier])
for (const [table, list] of Object.entries(rows)) {
  for (const row of list) {
    const columns = Object.keys(row)
    db.run(`INSERT INTO "${table}" (${columns.map((column) => `"${column}"`).join(', ')}) VALUES (${columns.map(() => '?').join(', ')})`, columns.map((column) => row[column]))
  }
}
const bytes = db.export()
db.close()

const SEQ = 120
const message = (kind, value) => JSON.stringify({ [kind]: { _0: value } })
const lines = [message('welcome', { protocolVersion: 1, daemon: { name: 'studio', id: '0F1C57A5-0000-4000-8000-000000000001', protocolVersion: 1 }, buildVersion: '1.0.0' })]
lines.push(message('snapshotBegin', { seq: SEQ, size: bytes.length }))
const CHUNK = 512 * 1024
for (let offset = 0; offset < bytes.length; offset += CHUNK) {
  lines.push(message('snapshotChunk', { data: Buffer.from(bytes.subarray(offset, offset + CHUNK)).toString('base64') }))
}
lines.push(message('snapshotEnd', { seq: SEQ, size: bytes.length }))
const idle = { canResume: true, isUpdatingMemory: false, setupFailed: false, isQueued: false, isSettingUp: false, isRunning: false, isStopping: false, queuedMessages: [] }
lines.push(message('live', {
  drivingRunIDs: [3, 4], waitingForCapacity: [], mcpReady: true, startedAt: '2026-11-25T09:00:00Z', usageRevision: 3,
  environment: { hostName: 'studio.local', homeDirectory: '/Users/dev', providerReady: true, processEnvironment: {} },
  agents: [3, idle, 13, { ...idle, isRunning: true, lastOutputAt: '2026-11-25T13:32:00Z' }],
}))

mkdirSync(dirname(out), { recursive: true })
writeFileSync(out, lines.join('\n') + '\n')
console.log(`Wrote ${lines.length} lines (${bytes.length} byte snapshot) to ${out}`)
