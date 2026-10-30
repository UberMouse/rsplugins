import { atom, update } from 'claude-code'
import type { Caught, EngineInterface, On, PromptSubmitResult } from 'claude-code'

import { INITIAL_IDLE } from './state-initial'
import { failureText, withSubmitReleased } from './util'

const IDLE = atom({ plugin: 'rsp-ops', key: 'idle' } as const, INITIAL_IDLE)

/** The `.catch` every idle hook carries: a failing hook logs and passes the event on. */
function passOn<E, R>($: EngineInterface, where: string, e: E, next: ((e: E) => R) & Caught): R {
  $.ui.log(failureText(where, next.error), { to: 'debug' })
  return next(e)
}

/**
 * Tracks whether the main loop is mid-turn, since when it has been idle, how many prompts were
 * typed over the running turn, and how many submitted while idle have yet to start theirs.
 * Autocompact reads IDLE rather than tracking turns itself. This file holds the plugin's one
 * matcher-less turn.start, turn.complete and prompt.submit (the engine refuses a second), and
 * registers before autocompact, so its turn.complete has marked the loop idle by the time
 * autocompact's runs. Ported from rs-sdk's rs-ops (kawaka's kx-ops, without its outbox).
 */
export function registerIdle(on: On): void {
  // A subagent's or teammate's turn raises turn.start too (since CC 2.1.299), and its turn.complete
  // is skipped below, so marking it running would leave the session busy until the main loop's
  // next turn ended.
  on('turn.start', async ($, e, next) => {
    if (e.agentId !== undefined) {
      return next(e)
    }
    await update($, IDLE, () => ({ running: true, idleSince: null, queued: 0, pendingSubmits: 0 }))
    return next(e)
  }).catch(($, e, next) => passOn($, 'idle turn.start', e, next))

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      const idleSince = new Date(await $.clock.now()).toISOString()
      await update($, IDLE, idle => ({ ...idle, running: false, idleSince, queued: 0 }))
    }
    return next(e)
  }).catch(($, e, next) => passOn($, 'idle turn.complete', e, next))

  // turnId is set only for a prompt typed over (or delivered into) a running turn; one without
  // starts a turn of its own, so it is pending until that turn starts. prompt.submit carries no
  // agentId: it is the session's own prompt, never a subagent's.
  on('prompt.submit', async ($, e, next) => {
    const isIdleSubmit = e.turnId === undefined
    await update($, IDLE, idle =>
      isIdleSubmit ? { ...idle, pendingSubmits: idle.pendingSubmits + 1 } : { ...idle, queued: idle.queued + 1 },
    )
    let result: PromptSubmitResult
    try {
      result = await next(e)
    } catch (error) {
      if (isIdleSubmit) {
        await update($, IDLE, withSubmitReleased)
      }
      throw error
    }
    // A dropped prompt starts no turn.
    if (result.drop !== undefined && isIdleSubmit) {
      await update($, IDLE, withSubmitReleased)
    }
    return result
  }).catch(($, e, next) => passOn($, 'idle prompt.submit', e, next))
}
