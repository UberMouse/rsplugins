# Recorder Demo (dev tool, not for submission)

A dev plugin that exercises the dev recorder (`lib/dev/`, linked in here as `dev/`) in the real
client. It reads a few vars (quest points, the run toggle, the in-game clock's minutes), your
display name, the backpack and a PersistentDB counter, and subscribes to VarTransmit,
InventoryUpdated, ServerLogic and ChatMessage. The recorder captures all of it and streams it to
a receiver on your own machine. How recording works, and the format, are in
[docs/testing.md](../../docs/testing.md#recordings).

## Use

1. From the repo root: `scripts/rsdev.py start` (writes to `dumps/recordings/`, gitignored).
2. In the client console: `prf`, `pon recorder-demo`, `ppr recorder-demo`, then
   `ppe recorder-demo httpAccess`, and for chat lines in the recording
   `ppe recorder-demo chatAccess`. Always `ppr` before `ppe`: `ppe` on a permission the plugin
   hasn't requested does nothing, silently. Be logged in.
3. Open the bank, or walk about. `dumps/recordings/recorder-demo/<time>-<session>.jsonl` grows,
   and the receiver prints a line per batch (about one a second).

What the console should show: `[RECDEMO] enabled N times`, one
`[RECORDER] waiting for httpAccess ...` line if the permission wasn't granted yet, and no
`[ERROR]`. Grep regex for this plugin's lines: `\[(RECDEMO|RECORDER)\]`.

What this checks in the client, which the test harness can't:

- the directory symlink `dev -> ../../lib/dev` loads (the recording grows; if the plugin runs unrecorded, copy instead, see docs/testing.md),
- the stand-ins work against the real API (no `[ERROR]`, and the recording has reads, events and
  `db` entries).

## Why it isn't for submission

It exists to record API traffic to a localhost URL for development. A plugin for submission
ships without `dev/`, the recorder lines in `main.lua`, and the recorder URL and permission.
