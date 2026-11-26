import { describe, expect, it } from 'vitest'
import { decodeJSONData, decodeLive, decodeMessage, encodeJSONData, encodeMessage } from '../src/protocol'

describe('protocol', () => {
  it('encodes enum cases the way Swift’s synthesized Codable does', () => {
    expect(JSON.parse(encodeMessage('hello', { clientID: 'A', protocolVersion: 1, lastSeq: 4 }))).toEqual({ hello: { _0: { clientID: 'A', protocolVersion: 1, lastSeq: 4 } } })
    expect(JSON.parse(encodeMessage('bye', undefined))).toEqual({ bye: {} })
  })

  it('decodes payloads and base64 command data', () => {
    const decoded = decodeMessage('{"result":{"_0":{"id":"X","ok":"eyJhIjoxfQ=="}}}')
    expect(decoded.kind).toBe('result')
    expect(decodeJSONData((decoded.value as { ok: string }).ok)).toEqual({ a: 1 })
    expect(decodeJSONData(encodeJSONData({ chatID: 3, text: 'hé' }))).toEqual({ chatID: 3, text: 'hé' })
    expect(decodeMessage('{"bye":{}}').kind).toBe('bye')
  })

  it('reads live agents in both dictionary encodings', () => {
    const agent = { isRunning: true, isStopping: false, isQueued: false, canResume: false, isSettingUp: false, setupFailed: false, isUpdatingMemory: false, queuedMessages: [] }
    const base = { drivingRunIDs: [1], waitingForCapacity: [], usageRevision: 0, environment: { hostName: 'h', homeDirectory: '/', providerReady: true }, mcpReady: true, startedAt: '' }
    expect(decodeLive({ ...base, agents: [74, agent] }).agents.get(74)?.isRunning).toBe(true)
    expect(decodeLive({ ...base, agents: { '74': agent } }).agents.get(74)?.isRunning).toBe(true)
  })
})
