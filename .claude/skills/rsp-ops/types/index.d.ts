// rsp-ops' $.state contract. Every value lives in $.state, never in a module variable, because a
// hot reload re-runs register() in a fresh environment and drops those.

/**
 * The main loop's turn state. Subagent turns never touch it: autocompact asks "is the conductor
 * idle", which only the main loop answers.
 */
export interface RspOpsIdle {
  running: boolean;
  /** ISO-8601 UTC of the last main-loop turn end; null while running or before the first turn ends. */
  idleSince: string | null;
  /**
   * Prompts submitted over the running turn. The engine folds them into that turn or starts
   * their own turn the moment it ends, so a turn boundary clears the count.
   */
  queued: number;
  /**
   * Prompts submitted while idle whose turn has not started yet. While it is non-zero a turn is
   * about to run; turn.start zeroes it, so a miscount lasts one turn at most.
   */
  pendingSubmits: number;
}

/** userConfig `autocompact`: global, from user settings; a change reloads the module. */
export type RspOpsAutocompactMode = 'on' | 'conductor-only' | 'off';

/** The failsafe's open window: armed for one idle episode, closed by typing or by its own timer. */
export interface RspOpsAutocompactWindow {
  /** Matches the arming's `failsafeSeq`, so a timer for a window already closed does nothing. */
  id: number;
  /** `rsp-ops.idle.idleSince` when it was armed: a turn in between ends the episode. */
  episode: string;
}

/**
 * Autocompact's session state. The global switch is the userConfig field, never `$.store`: a
 * user-scope userConfig applies live, in every session.
 */
export interface RspOpsAutocompact {
  /** `/rsp-autocompact on|off`, for this session only. */
  isSessionOn: boolean;
  /** The last measured `context.percent`; null when it read none (a fresh window, or just compacted). */
  percent: number | null;
  /** Whether a `session.measure` has been seen; until one has, a check asks `$.session.usage()`. */
  isMeasured: boolean;
  /** ISO-8601 UTC of the last attempt: a compaction, a `{skip}` veto or a failure all count. */
  lastAttemptAt: string | null;
  /** The first reading after the last attempt; a re-trigger needs `baseline + 10`. */
  baseline: number | null;
  /** A compaction stood and no defined reading has come since. */
  isAwaitingBaseline: boolean;
  failsafe: RspOpsAutocompactWindow | null;
  failsafeSeq: number;
  /** The idle episode whose failsafe the person cancelled; it does not re-arm within that episode. */
  cancelledFor: string | null;
  /**
   * The turn a prompt was typed over or delivered into, until the next turn starts: its end
   * starts no deferred check, and every check skips meanwhile, since a turn may follow.
   */
  queuedTurnId: string | null;
  /**
   * ISO-8601 UTC of when the `queuedTurnId` turn ended; null while it runs. A prompt delivered
   * into that turn starts none of its own, so the hold lapses QUEUED_HOLD_MS after this.
   */
  queuedTurnEndedAt: string | null;
  /** The last check's decision, for bare `/rsp-autocompact`; a check that acts sets it too. */
  lastCheck: RspOpsAutocompactCheck | null;
  /** `/rsp-autocompact stale on|off`: rule 3, the idle-hours compaction, for this session only. Off by default. */
  isStaleOn: boolean;
}

/** One autocompact check's outcome: what `decide` returned, and when. */
export interface RspOpsAutocompactCheck {
  /** ISO-8601 UTC. */
  at: string;
  /** The context percent it read; null when it read none or stopped before reading. */
  percent: number | null;
  rule: 'none' | 'conductor' | 'failsafe' | 'stale';
  reason: string;
}

declare module 'claude-code' {
  interface PluginState {
    'rsp-ops': {
      idle: RspOpsIdle;
      autocompact: RspOpsAutocompact;
    };
  }
}
