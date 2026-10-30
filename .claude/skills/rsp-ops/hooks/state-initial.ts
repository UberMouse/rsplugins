import type { RspOpsIdle } from '../types'

/**
 * The initial value of the `rsp-ops.idle` atom, which idle.tsx and autocompact.tsx each declare
 * (the validator rejects a shared atom module), so the two copies agree on it.
 */
export const INITIAL_IDLE: Readonly<RspOpsIdle> = { running: false, idleSince: null, queued: 0, pendingSubmits: 0 }
