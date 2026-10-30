import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { NOON, ROOT, mockSession, mockState, mockUi, passPrompts, passTurns, startSession } from './testkit'

const IDLE_KEY = 'rsp-ops.idle'

function world(on: On, drop?: () => string | undefined): Map<string, unknown> {
  const state = mockState(on)
  mockSession(on, { root: ROOT })
  mockUi(on)
  on('session.usage', () => ({ value: { startedAt: NOON, context: { window: 1_000_000, percent: undefined }, rateLimits: [] } }))
  passPrompts(on, drop)
  passTurns(on)
  return state
}

test('a main-loop turn marks the session running, and its end idle since then', async ($, on) => {
  const state = world(on)
  const clock = mock.clock(on, { now: NOON })
  await startSession($, clock)

  await $.turn.start({ text: 'go', turnId: 't1' })
  expect(state.get(IDLE_KEY)).toEqual({ running: true, idleSince: null, queued: 0, pendingSubmits: 0 })

  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  expect(state.get(IDLE_KEY)).toEqual({ running: false, idleSince: new Date(NOON).toISOString(), queued: 0, pendingSubmits: 0 })
})

test("a subagent's turn leaves the main loop's idle state alone", async ($, on) => {
  const state = world(on)
  const clock = mock.clock(on, { now: NOON })
  await startSession($, clock)
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
  const idle = state.get(IDLE_KEY)

  await $.turn.start({ text: '', turnId: 'sub-1', agentId: 'a1' })
  await $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 'sub-1', reason: 'answer', agentId: 'a1' })
  expect(state.get(IDLE_KEY)).toEqual(idle)
})

test('a prompt submitted while idle is pending until its turn starts; a dropped one gives the claim back', async ($, on) => {
  let dropping = false
  const state = world(on, () => (dropping ? 'dropped by a hook' : undefined))
  const clock = mock.clock(on, { now: NOON })
  await startSession($, clock)

  await $.prompt.submit({ text: 'hello', wait: false, origin: { kind: 'composer' } })
  expect((state.get(IDLE_KEY) as { pendingSubmits: number }).pendingSubmits).toBe(1)
  await $.turn.start({ text: 'hello', turnId: 't1' })
  expect((state.get(IDLE_KEY) as { pendingSubmits: number }).pendingSubmits).toBe(0)
  await $.turn.complete({ answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })

  dropping = true
  await $.prompt.submit({ text: 'ignored', wait: false, origin: { kind: 'composer' } })
  expect((state.get(IDLE_KEY) as { pendingSubmits: number }).pendingSubmits).toBe(0)
})
