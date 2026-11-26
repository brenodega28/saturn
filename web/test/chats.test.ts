import { describe, expect, it } from 'vitest'
import { chatStage, chatSummaries, groupChats } from '../src/chats'
import { decodeLive, decodeMessage } from '../src/protocol'
import { readRecords } from '../src/records'
import { Replica } from '../src/replica'
import { stageIndex } from '../src/thread'
import { readFixture } from './fixtureServer'
import { readSnapshot } from './helpers'

describe('chatStage mirrors ChatStage.of', () => {
  it('orders the rules like the Mac app', () => {
    expect(chatStage({ isClosed: true, closeReason: 'dropped' })).toBe('dropped')
    expect(chatStage({ isClosed: true, closeReason: 'done' })).toBe('done')
    expect(chatStage({ hold: { reason: 'step_failed' } })).toBe('stuck')
    expect(chatStage({ openRequests: ['loop_limit'] })).toBe('stuck')
    expect(chatStage({ latestRun: { status: 'interrupted' } })).toBe('stuck')
    expect(chatStage({ hold: { reason: 'approval' }, latestRun: { status: 'waitingOnYou' } })).toBe('needsYou')
    expect(chatStage({ pendingPermissions: 1 })).toBe('needsYou')
    expect(chatStage({ hasOpenProposal: true })).toBe('needsYou')
    expect(chatStage({ openRequests: ['notice', 'pin_review'] })).toBe('idle')
    expect(chatStage({ openRequests: ['question'] })).toBe('needsYou')
    expect(chatStage({ latestRun: { status: 'running' }, currentStep: { agent: 'checker', type: 'agent' } })).toBe('inReview')
    expect(chatStage({ latestRun: { status: 'running' }, currentStep: { type: 'gates' } })).toBe('inReview')
    expect(chatStage({ latestRun: { status: 'running' }, currentStep: { agent: 'builder', type: 'agent' } })).toBe('building')
    expect(chatStage({ leadIsWorking: true })).toBe('building')
    expect(chatStage({ isFinished: true })).toBe('finished')
    expect(chatStage({ latestRun: { status: 'succeeded' } })).toBe('finished')
    expect(chatStage({})).toBe('idle')
  })

  it('maps stages onto the stage bar like StageBar.current', () => {
    expect(stageIndex('idle', false)).toBe(0)
    expect(stageIndex('needsYou', true)).toBe(1)
    expect(stageIndex('needsYou', false)).toBe(0)
    expect(stageIndex('inReview', true)).toBe(2)
    expect(stageIndex('finished', true)).toBe(4)
  })

  it('groups by rank, then latest activity, like ChatGroup.grouped', () => {
    const at = (minute: number) => new Date(Date.UTC(2026, 10, 25, 10, minute))
    const groups = groupChats([
      { id: 'a', stage: 'stuck' as const, lastActivity: at(9) },
      { id: 'b', stage: 'needsYou' as const, lastActivity: at(1) },
      { id: 'c', stage: 'building' as const, lastActivity: at(5) },
      { id: 'd', stage: 'inReview' as const, lastActivity: at(2) },
      { id: 'e', stage: 'idle' as const, lastActivity: at(3) },
      { id: 'f', stage: 'done' as const, lastActivity: at(3) },
    ])
    expect(groups.needsYou.map((item) => item.id)).toEqual(['b', 'a'])
    expect(groups.inProgress.map((item) => item.id)).toEqual(['d', 'c'])
    expect(groups.notStarted.map((item) => item.id)).toEqual(['e'])
    expect(groups.finished).toEqual([])
  })
})

describe('chat summaries from the fixture', () => {
  it('reaches the same statuses as the Mac app', async () => {
    const replica = new Replica(readSnapshot)
    let live = decodeLive({ agents: [], drivingRunIDs: [], waitingForCapacity: [], usageRevision: 0, environment: { hostName: '', homeDirectory: '', providerReady: true }, mcpReady: true, startedAt: '' })
    for (const line of readFixture('mobile-v6.jsonl')) {
      const message = decodeMessage(line)
      if (message.kind === 'snapshotBegin') replica.beginSnapshot()
      if (message.kind === 'snapshotChunk') replica.addChunk(message.value.data)
      if (message.kind === 'snapshotEnd') await replica.endSnapshot(message.value.seq)
      if (message.kind === 'live') live = decodeLive(message.value)
    }
    const { open, closed } = chatSummaries(readRecords(replica), live)
    const stages = Object.fromEntries([...open, ...closed].map((summary) => [summary.chat.id, summary.stage]))
    expect(stages).toEqual({ 1: 'needsYou', 2: 'stuck', 3: 'needsYou', 4: 'building', 5: 'idle', 6: 'idle', 7: 'finished', 8: 'dropped', 9: 'needsYou' })
    const hamburger = open.find((summary) => summary.chat.id === 3)!
    expect(hamburger.costUSD).toBeCloseTo(4.15)
    expect(hamburger.workers.map((agent) => agent.name)).toEqual(['Front-end Dev', 'Reviewer'])
    expect(open.find((summary) => summary.chat.id === 1)!.isUnread).toBe(true)
    expect(open.find((summary) => summary.chat.id === 7)!.workers).toEqual([])
    expect(closed.map((summary) => summary.chat.id)).toEqual([8])
  })
})
