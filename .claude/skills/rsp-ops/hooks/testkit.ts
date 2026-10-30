import type { On } from 'claude-code'
import type { Engine, MockClock } from 'claude-code/testing'

/**
 * The engine beneath rsp-ops for the feature tests: fixtures and the hooks every test world is
 * built from. A test's hooks sit beneath every plugin and, among themselves, the first registered
 * is outermost, so a test registers its special cases before these and falls through via `next`.
 * Ported from rs-sdk's rs-ops (trimmed from kawaka's kx-ops).
 */

export const NOON = Date.UTC(2026, 9, 6, 12, 0, 0)
export const MINUTE = 60_000
export const ROOT = '/home/u/rsplugins'
export const SID = '995a3baa-fecc-4c6a-a63f-f540f7fad18d'
export const STATE_JSON = `${ROOT}/.durable-state/state.json`

/**
 * `$.state` for a test: the kit serves no noun the test does not hook, so these hooks stand in
 * for the host beneath the plugin, compare-and-set included (`update` writes with ifVersion).
 * A call on `$` answers its hooks as `{ value }`, so each hook wraps the host's own result.
 * Returns the store, keyed `<plugin>.<key>`, for the test to seed and read.
 */
export function mockState(on: On, seed: Readonly<Record<string, unknown>> = {}): Map<string, unknown> {
  const values = new Map<string, unknown>(Object.entries(seed))
  const versions = new Map<string, number>(Object.keys(seed).map(name => [name, 1]))
  on('state.get', (_$, e) => {
    const name = `${e.plugin}.${e.key}`
    return { value: { value: values.get(name), version: versions.get(name) ?? 0 } }
  })
  on('state.set', (_$, e) => {
    const name = `${e.plugin}.${e.key}`
    const version = versions.get(name) ?? 0
    if (e.ifVersion !== undefined && e.ifVersion !== version) {
      return { value: { isSet: false as const, version } }
    }
    values.set(name, e.value)
    versions.set(name, version + 1)
    return { value: { isSet: true as const, version: version + 1 } }
  })
  return values
}

/** The session nouns: start and end echoed, root, id, command registration. */
export function mockSession(on: On, options: { root: string }): void {
  on('session.start', (_$, e) => ({ cwd: e.cwd }))
  on('session.end', (_$, e) => ({ sessionId: e.sessionId }))
  on('session.root', () => ({ value: options.root }))
  on('session.id', () => ({ value: SID }))
  on('command.register', (_$, e) => ({ value: { command: e.name } }))
}

/** What reached the UI beneath the plugins. */
export interface FakeUi {
  logs: string[];
  toasts: string[];
  statuses: (string | undefined)[];
}

/** The UI nouns, recorded: log, toast and status line. */
export function mockUi(on: On): FakeUi {
  const ui: FakeUi = { logs: [], toasts: [], statuses: [] }
  on('ui.log', (_$, e) => {
    ui.logs.push(e.text)
    return { value: undefined }
  })
  on('ui.toast', (_$, e) => {
    ui.toasts.push(e.text)
    return { value: undefined }
  })
  on('ui.status', (_$, e) => {
    ui.statuses.push(e.text)
    return { value: undefined }
  })
  return ui
}

/** The file system beneath the plugins (exists and read only), for the test to seed. */
export function mockFs(on: On, seed: Readonly<Record<string, string>> = {}): Map<string, string> {
  const files = new Map(Object.entries(seed))
  on('fs.exists', (_$, e) => ({ value: files.has(e.path) }))
  on('fs.read', (_$, e) => {
    const text = files.get(e.path)
    if (text === undefined) {
      throw new Error(`ENOENT: ${e.path}`)
    }
    return { value: text }
  })
  return files
}

/** Turn starts and ends, answered as core would. */
export function passTurns(on: On): void {
  on('turn.start', (_$, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
}

/** `prompt.submit`, let through with its text and context; `drop` answers a drop when set. */
export function passPrompts(on: On, drop?: () => string | undefined): void {
  on('prompt.submit', (_$, e) => {
    const dropped = drop?.()
    return dropped === undefined ? { text: e.text, context: e.context } : { drop: dropped }
  })
}

export async function startSession($: Engine, clock: MockClock, root: string = ROOT): Promise<void> {
  await $.session.start({ cwd: root, surface: 'terminal', isInteractive: true })
  await clock.settle()
}
