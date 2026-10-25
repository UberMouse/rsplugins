# Recorder Demo (dev tool, not for submission)

A dev plugin that exercises the dev recorder (`lib/dev/`, linked in here as `dev/`) in the real
client. It reads a few vars (quest points, the run toggle, the in-game clock's minutes), your
display name, the backpack and a PersistentDB counter, and subscribes to VarTransmit,
InventoryUpdated, ServerLogic and ChatMessage. The recorder captures all of it and streams it to
a receiver on your own machine. How recording works, and the format, are in
[docs/testing.md](../../docs/testing.md#recordings).

On enable it also logs one probe line about the client's Lua environment, which the docs don't
describe: `_VERSION`, whether `os` and `io` exist, what `os.time()`, `os.date()` and `os.clock()`
return, whether the recorder loaded, and whether a `require`d module shares `main.lua`'s globals
(`moduleSharesEnv`, `moduleSeesSameEvent`). That last answer says whether the recorder also sees
what a plugin's other modules do.

## Use

1. From the repo root: `scripts/dev-receiver.py` (writes to `dumps/recordings/`, gitignored).
2. In the client console: `prf`, `pon recorder-demo`, `ppr recorder-demo`, then
   `ppe recorder-demo httpAccess`, and for chat lines in the recording
   `ppe recorder-demo chatAccess`. Always `ppr` before `ppe`: `ppe` on a permission the plugin
   hasn't requested does nothing, silently. Be logged in.
3. Open the bank, or walk about. `dumps/recordings/recorder-demo/<time>-<session>.jsonl` grows,
   and the receiver prints a line per batch (about one a second).

What the console should show: one `[RECDEMO] probe: ...` line, `[RECDEMO] enabled N times`, one
`[RECORDER] waiting for httpAccess ...` line if the permission wasn't granted yet, and no
`[ERROR]`. Grep regex for this plugin's lines: `\[(RECDEMO|RECORDER)\]`.

What this checks in the client, which the test harness can't:

- the directory symlink `dev -> ../../lib/dev` loads (`recorder=true` in the probe line; if it
  says `false`, copy instead, see docs/testing.md),
- the stand-ins work against the real API (no `[ERROR]`, and the recording has reads, events and
  `db` entries),
- what the probe reports.

## Why it isn't for submission

It exists to record API traffic to a localhost URL for development. A plugin for submission
ships without `dev/`, the recorder lines in `main.lua`, and the recorder URL and permission.
