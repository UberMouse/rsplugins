import { expect, test } from 'claude-code/testing'

import {
  AUTOCOMPACT_CANCELLED_TOAST,
  AUTOCOMPACT_FAILSAFE_TOAST,
  conductorInstructions,
  failsafeInstructions,
  staleInstructions,
  statusText,
} from './autocompact-model'

/**
 * Every text rsp-ops puts in front of the model or the person names rsp-ops first. The transcript
 * records a compaction's instructions with no plugin field, so the text is the only way to tell
 * which mod wrote it. A compaction's instructions open with the provenance line, so their second
 * line is the one held to the prefix. Toasts and status lines are held to `rsp-ops <feature>: `.
 */

const MODEL = /^rsp-ops[ :]/
const TOAST_OR_STATUS = /^rsp-ops autocompact: /

function secondLine(text: string): string {
  return text.split('\n')[1] ?? ''
}

const BRIEF = { percent: 40, statePath: '/r/.durable-state/state.json', inFlight: [{ kind: 'agent', id: 'a1', what: 'runner' }], standing: [] }

// A new text belongs in this table, or it ships unchecked.
const TEXTS: Readonly<Record<string, { text: string; opens: RegExp }>> = {
  'conductorInstructions': { text: secondLine(conductorInstructions(BRIEF)), opens: MODEL },
  'failsafeInstructions': { text: secondLine(failsafeInstructions(80)), opens: MODEL },
  'staleInstructions': { text: secondLine(staleInstructions(30, 7 * 3_600_000)), opens: MODEL },
  'statusText compacted': { text: statusText('conductor', 40, null), opens: TOAST_OR_STATUS },
  'statusText vetoed': { text: statusText('failsafe', 80, 'blocked'), opens: TOAST_OR_STATUS },
  'AUTOCOMPACT_FAILSAFE_TOAST': { text: AUTOCOMPACT_FAILSAFE_TOAST, opens: TOAST_OR_STATUS },
  'AUTOCOMPACT_CANCELLED_TOAST': { text: AUTOCOMPACT_CANCELLED_TOAST, opens: TOAST_OR_STATUS },
}

test('every rsp-ops text names rsp-ops first', () => {
  for (const [name, { text, opens }] of Object.entries(TEXTS)) {
    expect({ name, isNamed: opens.test(text) }).toEqual({ name, isNamed: true })
  }
})
