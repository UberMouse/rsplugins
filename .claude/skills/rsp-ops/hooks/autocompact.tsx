import { atom, read, update } from 'claude-code'
import type { Caught, EngineInterface, On, Timer } from 'claude-code'

import type { RspOpsAutocompactMode } from '../types'
import {
  AUTOCOMPACT_CANCELLED_TOAST,
  AUTOCOMPACT_FAILSAFE_TOAST,
  CONDUCTOR_PERCENT,
  DEFER_MS,
  FAILSAFE_PERCENT,
  FAILSAFE_WINDOW_MS,
  RUN_STATE_FILE,
  STALE_IDLE_MS,
  STALE_PERCENT,
  TICK_MS,
  canRetrigger,
  conductorInstructions,
  conductorStatus,
  decide,
  diagnosticLines,
  failsafeInstructions,
  isQueuedHold,
  staleInstructions,
  standingInstructions,
  statusBody,
  statusText,
  wakingInFlight,
  withReading,
} from './autocompact-model'
import type { AutocompactDecision, AutocompactRule, ConductorStatus } from './autocompact-model'
import { INITIAL_IDLE } from './state-initial'
import { failureText, isIdle, msSince } from './util'

const AUTOCOMPACT = atom({ plugin: 'rsp-ops', key: 'autocompact' } as const, {
  isSessionOn: true,
  percent: null,
  isMeasured: false,
  lastAttemptAt: null,
  baseline: null,
  isAwaitingBaseline: false,
  failsafe: null,
  failsafeSeq: 0,
  cancelledFor: null,
  queuedTurnId: null,
  queuedTurnEndedAt: null,
  lastCheck: null,
  isStaleOn: false,
})
const IDLE = atom({ plugin: 'rsp-ops', key: 'idle' } as const, INITIAL_IDLE)

// Not `autocompact`: that is Claude Code's built-in (the engine's own threshold), which
// `$.command.register` refuses and a command.run hook on it would shadow.
const COMMAND = 'rsp-autocompact'
const STATUS_MS = 10 * 60_000

/**
 * What this load holds that `$.state` cannot: the tick and the status line's clear belong to the
 * load (a hot reload cancels timers), and `isChecking` keeps a tick and a deferred check apart.
 */
interface AutocompactHandles {
  tick: Timer | null;
  isChecking: boolean;
  statusSeq: number;
}

/** A decision worth keeping, to the debug log. */
function logLine($: EngineInterface, message: string): void {
  $.ui.log(`rsp-ops: autocompact ${message}`, { to: 'debug' })
}

function logFailure($: EngineInterface, where: string, error: unknown): void {
  $.ui.log(failureText(`autocompact ${where}`, error), { to: 'debug' })
}

/** The `.catch` every autocompact hook carries: a failing hook logs and passes the event on. */
function passOn<E, R>($: EngineInterface, where: string, e: E, next: ((e: E) => R) & Caught): R {
  logFailure($, where, next.error)
  return next(e)
}

/** The run's state.json, parsed, and where it was; null when there is none or it does not parse. */
async function readRunState($: EngineInterface, root: string): Promise<{ path: string; json: unknown } | null> {
  const path = `${root}/${RUN_STATE_FILE}`
  if (!(await $.fs.exists(path))) {
    return null
  }
  try {
    return { path, json: JSON.parse(await $.fs.read(path)) }
  } catch (error) {
    logFailure($, `read of ${path}`, error)
    return null
  }
}

/**
 * The context percent: the last `session.measure`'s, or `$.session.usage()` when none has been
 * seen this session. Undefined (fresh window, or just compacted) means do nothing, never 0.
 */
async function currentPercent($: EngineInterface): Promise<number | undefined> {
  const ac = await read($, AUTOCOMPACT)
  if (ac.isMeasured) {
    return ac.percent ?? undefined
  }
  return (await $.session.usage()).context.percent
}

/** Pins the status line, and clears it STATUS_MS later unless a newer one replaced it. */
function showStatus($: EngineInterface, handles: AutocompactHandles, text: string): void {
  handles.statusSeq += 1
  const seq = handles.statusSeq
  $.ui.status(text)
  $.clock.after(STATUS_MS, () => {
    if (handles.statusSeq === seq) {
      $.ui.status(undefined)
    }
  })
}

/**
 * One attempt. The slot is claimed with one compare-and-set, so a tick and a deferred check never
 * both compact. A `{skip}` veto (a hook's, or a classic PreCompact block) is debounced like a
 * compaction; so is a failure, except a rejection because a turn started in between.
 */
async function compactNow(
  $: EngineInterface,
  handles: AutocompactHandles,
  rule: AutocompactRule,
  percent: number,
  instructions: string,
): Promise<void> {
  if (!isIdle(await read($, IDLE))) {
    return
  }
  const now = await $.clock.now()
  let previous: string | null = null
  let isClaimed = false
  await update($, AUTOCOMPACT, ac => {
    isClaimed = !isQueuedHold(ac, now) && canRetrigger(ac, percent, now)
    previous = ac.lastAttemptAt
    return isClaimed ? { ...ac, lastAttemptAt: new Date(now).toISOString(), failsafe: null } : ac
  })
  if (!isClaimed) {
    return
  }
  logLine($, `${rule}: compacting at ${percent}%`)
  let skip: string | null
  try {
    const result = await $.session.compact({ instructions })
    skip = result.skip ?? null
  } catch (error) {
    const isTurnRace = !isIdle(await read($, IDLE))
    logFailure($, `${rule} compact${isTurnRace ? ' (a turn started; slot released)' : ''}`, error)
    const released: string | null = previous
    await update($, AUTOCOMPACT, ac => (isTurnRace ? { ...ac, lastAttemptAt: released } : { ...ac, baseline: percent, isAwaitingBaseline: false }))
    return
  }
  logLine($, statusBody(rule, percent, skip))
  showStatus($, handles, statusText(rule, percent, skip))
  if (skip === null) {
    // The window reads no percent until its next response; that first reading is the baseline.
    await update($, AUTOCOMPACT, ac => ({ ...ac, percent: null, baseline: null, isAwaitingBaseline: true }))
  } else {
    await update($, AUTOCOMPACT, ac => ({ ...ac, baseline: percent, isAwaitingBaseline: false }))
  }
}

/** Opens the failsafe's window for this idle episode: a toast now, the compaction in 60 s. */
async function armFailsafe($: EngineInterface, handles: AutocompactHandles, mode: RspOpsAutocompactMode, episode: string): Promise<void> {
  let id = 0
  await update($, AUTOCOMPACT, ac => {
    if (ac.failsafe !== null || ac.cancelledFor === episode) {
      return ac
    }
    id = ac.failsafeSeq + 1
    return { ...ac, failsafeSeq: id, failsafe: { id, episode } }
  })
  if (id === 0) {
    return
  }
  const armed = id
  logLine($, `failsafe armed (window ${armed})`)
  $.ui.toast(AUTOCOMPACT_FAILSAFE_TOAST)
  $.clock.after(FAILSAFE_WINDOW_MS, () => {
    void fireFailsafe($, handles, mode, armed).catch(error => logFailure($, 'failsafe', error))
  })
}

/** The failsafe's window closed untouched: compact if the same idle episode still qualifies. */
async function fireFailsafe($: EngineInterface, handles: AutocompactHandles, mode: RspOpsAutocompactMode, id: number): Promise<void> {
  let episode: string | null = null
  await update($, AUTOCOMPACT, ac => {
    if (ac.failsafe?.id !== id) {
      return ac
    }
    episode = ac.failsafe.episode
    return { ...ac, failsafe: null }
  })
  const armedFor: string | null = episode
  if (armedFor === null) {
    return
  }
  const idle = await read($, IDLE)
  const ac = await read($, AUTOCOMPACT)
  const percent = await currentPercent($)
  if (
    mode !== 'on' ||
    !ac.isSessionOn ||
    isQueuedHold(ac, await $.clock.now()) ||
    idle.idleSince !== armedFor ||
    percent === undefined ||
    percent < FAILSAFE_PERCENT
  ) {
    logLine($, 'failsafe window closed without compacting (the session moved on)')
    return
  }
  await compactNow($, handles, 'failsafe', percent, failsafeInstructions(percent))
}

/** Closes an open failsafe window; the person typed, or a prompt arrived. */
async function cancelFailsafe($: EngineInterface, why: string, isPerson: boolean): Promise<void> {
  if ((await read($, AUTOCOMPACT)).failsafe === null) {
    return
  }
  let isCancelled = false
  await update($, AUTOCOMPACT, ac => {
    isCancelled = ac.failsafe !== null
    return ac.failsafe === null ? ac : { ...ac, failsafe: null, cancelledFor: ac.failsafe.episode }
  })
  if (isCancelled) {
    logLine($, `failsafe cancelled (${why})`)
    if (isPerson) {
      $.ui.toast(AUTOCOMPACT_CANCELLED_TOAST)
    }
  }
}

/**
 * Keeps a check's decision for bare `/rsp-autocompact` and logs it to the debug log, so a check
 * that did nothing still says why.
 */
async function recordCheck($: EngineInterface, decision: AutocompactDecision, percent: number | undefined, now: number): Promise<void> {
  const lastCheck = { at: new Date(now).toISOString(), percent: percent ?? null, rule: decision.rule, reason: decision.reason }
  await update($, AUTOCOMPACT, ac => ({ ...ac, lastCheck }))
  logLine($, `check${percent === undefined ? '' : ` at ${percent}%`}: ${decision.rule}: ${decision.reason}`)
}

/** Rule 1's view of this session's run. */
async function readConductor($: EngineInterface): Promise<{ run: { path: string; json: unknown } | null; status: ConductorStatus }> {
  const run = await readRunState($, await $.session.root())
  return { run, status: conductorStatus(run, await $.session.id()) }
}

/** One check: rule 1 or 3, else rule 2's window. Runs from turn.complete (deferred) and the tick. */
async function check($: EngineInterface, handles: AutocompactHandles, mode: RspOpsAutocompactMode): Promise<void> {
  if (mode === 'off' || handles.isChecking) {
    return
  }
  handles.isChecking = true
  try {
    const idle = await read($, IDLE)
    const before = await read($, AUTOCOMPACT)
    const now = await $.clock.now()
    // IDLE reads idle between a turn's end and the start of the prompt typed over it: idle.tsx
    // zeroes `queued` at the end, and that prompt is no pending submit.
    if (!isIdle(idle) || !before.isSessionOn || isQueuedHold(before, now)) {
      // No reading taken: `decide` stops at the same gate before it needs one.
      await recordCheck($, decide({ mode, ac: before, idle, percent: undefined, conductor: null, now }), undefined, now)
      return
    }
    const percent = await currentPercent($)
    if (percent === undefined) {
      await recordCheck($, decide({ mode, ac: before, idle, percent, conductor: null, now }), percent, now)
      return
    }
    const ac = await update($, AUTOCOMPACT, current => withReading(current, percent))
    // state.json matters only above rule 1's threshold.
    const conductor = percent > CONDUCTOR_PERCENT ? await readConductor($) : null
    const run = conductor?.run ?? null
    const decision = decide({ mode, ac, idle, percent, conductor: conductor?.status ?? null, now })
    await recordCheck($, decision, percent, now)
    const rule = decision.rule
    if (rule === 'conductor' && run !== null) {
      const brief = { percent, statePath: run.path, inFlight: wakingInFlight(run.json), standing: standingInstructions(run.json) }
      await compactNow($, handles, 'conductor', percent, conductorInstructions(brief))
    } else if (rule === 'stale') {
      await compactNow($, handles, 'stale', percent, staleInstructions(percent, msSince(idle.idleSince, now) ?? 0))
    } else if (rule === 'failsafe' && idle.idleSince !== null) {
      await armFailsafe($, handles, mode, idle.idleSince)
    }
  } finally {
    handles.isChecking = false
  }
}

function startTick($: EngineInterface, handles: AutocompactHandles, mode: RspOpsAutocompactMode): void {
  handles.tick?.cancel()
  handles.tick = $.clock.every(TICK_MS, () => {
    void check($, handles, mode).catch(error => logFailure($, 'tick', error))
  })
}

function staleCommandText(isStaleOn: boolean): string {
  return isStaleOn
    ? `the idle-hours rule is on for this session: idle ${STALE_IDLE_MS / 3_600_000} h at ${STALE_PERCENT}% or more compacts, unless autocompact is off.`
    : 'the idle-hours rule is off for this session.'
}

function commandText(mode: RspOpsAutocompactMode, isSessionOn: boolean): string {
  const global = mode === 'off' ? 'off, so nothing compacts' : mode
  return `autocompact is ${isSessionOn ? 'on' : 'off'} for this session (global setting: ${global}; change it with claude plugin configure rsp-ops@skills-dir).`
}

/**
 * Idle autocompaction of the main conversation. Rule 1 compacts an idle conductor (an sdd-loop
 * run, not done, its state.json naming this session) over 25% while its hand-kept inFlight
 * holds work that will wake it. Rule 3 (opt-in) compacts a session idle for hours. Rule 2, the
 * failsafe, gives any other idle session at 75% a 60 s cancellable window. `mode` is the global
 * userConfig switch; `/rsp-autocompact on|off` is this session's own. idle.tsx holds the
 * matcher-less turn.start, turn.complete and prompt.submit, so those here carry a matcher every
 * input satisfies.
 */
export function registerAutocompact(on: On, mode: RspOpsAutocompactMode): void {
  const handles: AutocompactHandles = { tick: null, isChecking: false, statusSeq: 0 }

  on('session.start', async ($, e, next) => {
    await $.command
      .register({ name: COMMAND, description: 'rsp-ops: idle auto-compaction for this session: on|off, stale on|off' })
      .catch(error => logFailure($, 'command.register', error))
    // A reload dropped the previous load's timers, the failsafe's among them: its window is gone.
    await update($, AUTOCOMPACT, ac => (ac.failsafe === null ? ac : { ...ac, failsafe: null }))
    if (mode !== 'off') {
      startTick($, handles, mode)
    }
    return next(e)
  }).catch(($, e, next) => passOn($, 'session.start', e, next))

  on('session.end', async ($, e, next) => {
    // A /clear ends the conversation, not the process: a fresh window has no reading yet.
    if (e.reason === 'clear') {
      await update($, AUTOCOMPACT, ac => ({ ...ac, percent: null, isMeasured: false, failsafe: null }))
    } else {
      handles.tick?.cancel()
      handles.tick = null
    }
    return next(e)
  }).catch(($, e, next) => passOn($, 'session.end', e, next))

  // The turn a typed-over prompt was waiting for has started, so checks may run again once it
  // ends. A subagent's turn is not that turn: the hold stands.
  on('turn.start', { turnId: /^/ }, async ($, e, next) => {
    if (e.agentId !== undefined) {
      return next(e)
    }
    await update($, AUTOCOMPACT, ac => (ac.queuedTurnId === null ? ac : { ...ac, queuedTurnId: null, queuedTurnEndedAt: null }))
    return next(e)
  }).catch(($, e, next) => passOn($, 'turn.start', e, next))

  // idle.tsx's turn.complete runs first, so IDLE is already idle here.
  on('turn.complete', { turnId: /^/ }, async ($, e, next) => {
    if (e.agentId !== undefined) {
      return next(e)
    }
    // A prompt submitted into this turn holds every check off: the turn.start above clears the way
    // and that turn's own end schedules the next check, or, when no turn starts, the hold lapses
    // and the tick checks.
    const { queuedTurnId } = await read($, AUTOCOMPACT)
    if (queuedTurnId === e.turnId) {
      const endedAt = new Date(await $.clock.now()).toISOString()
      await update($, AUTOCOMPACT, ac => (ac.queuedTurnId === e.turnId ? { ...ac, queuedTurnEndedAt: endedAt } : ac))
    }
    if (mode !== 'off' && queuedTurnId === null) {
      // `compact` would hold this hook for the whole compaction, so the check runs on its own.
      $.clock.after(DEFER_MS, () => {
        void check($, handles, mode).catch(error => logFailure($, 'deferred check', error))
      })
    }
    return next(e)
  }).catch(($, e, next) => passOn($, 'turn.complete', e, next))

  // Every prompt has text, so this sees them all.
  on('prompt.submit', { text: /^/ }, async ($, e, next) => {
    if (e.turnId !== undefined) {
      const turnId = e.turnId
      await update($, AUTOCOMPACT, ac => ({ ...ac, queuedTurnId: turnId, queuedTurnEndedAt: null }))
    }
    await cancelFailsafe($, `prompt.submit from ${e.origin.kind}`, e.origin.kind === 'composer')
    return next(e)
  }).catch(($, e, next) => passOn($, 'prompt.submit', e, next))

  // Every keystroke: the box must not wait on the state read, so the cancel runs beside it.
  on('prompt.edit', ($, e, next) => {
    void cancelFailsafe($, 'prompt.edit', true).catch(error => logFailure($, 'prompt.edit cancel', error))
    return next(e)
  }).catch(($, e, next) => passOn($, 'prompt.edit', e, next))

  // A recalled prompt, an undo or a clear raises no prompt.edit, yet each still means the person is
  // at the keyboard. A plugin's fill does not, and `engine` mixes the person's writes with a prefill.
  on('prompt.change', ($, e, next) => {
    const { kind } = e.origin
    if (kind === 'history' || kind === 'undo' || kind === 'clear') {
      void cancelFailsafe($, `prompt.change (${kind})`, true).catch(error => logFailure($, 'prompt.change cancel', error))
    }
    return next(e)
  }).catch(($, e, next) => passOn($, 'prompt.change', e, next))

  // The reading every check uses. A subagent's window never reaches here: measure is the main one.
  on('session.measure', async ($, e, next) => {
    const percent = e.context.percent
    await update($, AUTOCOMPACT, ac => withReading({ ...ac, percent: percent ?? null, isMeasured: true }, percent))
    return next(e)
  }).catch(($, e, next) => passOn($, 'session.measure', e, next))

  // Observes compactions rsp-ops did not make (/compact, the engine's threshold, another plugin):
  // the window reads no percent until its next response, so the last measure is stale. rsp-ops'
  // own compact is a timer's call, which skips this plugin's hooks.
  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (e.agentId === undefined && e.trigger !== 'precompute' && result.skip === undefined) {
      await update($, AUTOCOMPACT, ac => ({ ...ac, percent: null }))
    }
    return result
  }).catch(($, e, next) => passOn($, 'session.compact', e, next))

  on('command.run', { command: COMMAND }, async ($, e) => {
    const arg = e.args.trim().toLowerCase().replace(/\s+/g, ' ')
    if (arg === 'stale on' || arg === 'stale off') {
      const isStaleOn = arg === 'stale on'
      await update($, AUTOCOMPACT, ac => ({ ...ac, isStaleOn }))
      logLine($, `idle-hours rule (3) switched ${isStaleOn ? 'on' : 'off'} for this session`)
      return { text: staleCommandText(isStaleOn) }
    }
    if (arg !== '' && arg !== 'on' && arg !== 'off') {
      return { text: `Usage: /${COMMAND} on|off|stale on|stale off. ${commandText(mode, (await read($, AUTOCOMPACT)).isSessionOn)}` }
    }
    if (arg !== '') {
      const isSessionOn = arg === 'on'
      await update($, AUTOCOMPACT, ac => ({ ...ac, isSessionOn, failsafe: isSessionOn ? ac.failsafe : null }))
      return { text: commandText(mode, (await read($, AUTOCOMPACT)).isSessionOn) }
    }
    // Bare: the switches, then everything a check reads, with state.json read whatever the percent.
    const ac = await read($, AUTOCOMPACT)
    const now = await $.clock.now()
    const percent = await currentPercent($)
    const conductor = await readConductor($)
    const decision = decide({ mode, ac, idle: await read($, IDLE), percent, conductor: conductor.status, now })
    const lines = diagnosticLines({ ac, percent, isTicking: handles.tick !== null, conductor: conductor.status, now: decision, nowMs: now })
    return { text: [commandText(mode, ac.isSessionOn), ...lines].join('\n') }
  }).catch(($, e, next) => passOn($, 'command.run', e, next))
}
