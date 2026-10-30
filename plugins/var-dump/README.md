# Var Dump (dev tool, not for submission)

Dumps every game variable the client can read for your own character, and then logs every
update the server sends. The data goes to a small receiver on your own machine, so you can work
out what vars mean (e.g. change a setting, see which var flips).

It reads VarPlayer and VarClient, including their VarBits. Only vars the server sends to the
client are visible, so "every" means "every one the client knows about".

## Use

1. Start the receiver from the repo root: `scripts/var-dump-receiver.py` (writes to
   `dumps/var-dump/`, which is gitignored).
2. In the client console: `prf`, `pon var-dump`, `ppr var-dump`, then
   `ppe var-dump httpAccess`. The plugin starts dumping as soon as the permission is granted.
   Type the `ppe` in the console yourself: sending it through the dev bridge crashed the client
   when recorder-demo was running with httpAccess (see "Crash 9" in
   [api-concepts.md](../../docs/api-concepts.md#seen-with-dev-bridge-2026-10-26)).
   Be logged in first, or the snapshot is empty. (`httpAccess` is optional rather than required
   because `requiredPermissions` is currently broken in the client.)
3. Each enable/reload writes a new `snapshot-<time>.jsonl`. While the plugin is on, updates are
   appended to `changes.jsonl`.

Console lines from the plugin are tagged `[VARDUMP]` (grep regex: `\[VARDUMP\]`).

## Building the var catalog

The plugin tests (`scripts/test-lua.sh`, and so `scripts/check.sh`) need `docs/vars/`, the
catalog of every var's name, ID, type and VarBit layout. It isn't committed, so build it once
per checkout: take a snapshot as above, then run
`python3 -I scripts/var-dump-analyze.py --catalog` from the repo root. That writes
`docs/vars/vars.csv`, `families.txt` and a README on how to look vars up. The catalog holds no
values, but it reflects the game build you dumped from; redump after an update adds vars.

## Output

`snapshot-*.jsonl`, one var per line:

```json
{"domain": "VarPlayer", "id": -30174, "name": "FRIEND_SORT_MODE", "valueType": 0,
 "valueTypeName": "INTEGER", "value": 5, "isVarBit": true, "baseVar": "OPTION_TOGGLE1", "mask": 56}
```

`changes.jsonl`, one VarTransmit event per line. `seq` is the order the events arrived in,
`tick` is the number of server ticks since the plugin was enabled, and `received` is the
receiver's Unix time. A missing `old`/`new` means nil. Events fire even when the value didn't
change.

```json
{"seq": 1, "tick": 12, "domain": "VarPlayer", "id": 5967, "name": "OPTION_TOGGLE1", "old": 40, "new": 48, "received": 1792446724.0}
```

To find which var something you do in game moves, run
`python3 -I scripts/var-dump-changes.py --last-session` and note its `last seq`, do it, then
rerun with `--after <seq>`. It prints each change in order with the VarBits it moved (an update
can name the base var rather than the VarBit); `--match <regex>` narrows it.

Config-typed values (NPC, Obj, ...) are written as `{"config": NAME, "id": n}`. Other game types
(e.g. CoordGrid) are written as their text form. If a value couldn't be read, there's an
`error` field instead of `value`.

## How it finds the vars

The API documents lookup by name and by ID, but not how to list every var. The plugin first
tries `pairs(id.VarPlayer)` / `pairs(id.VarClient)`. If that fails, it tries every ID from
`SCAN_MIN` to `SCAN_MAX` with `FromID` (VarBits have negative IDs). The console says which
method each domain used and the lowest and highest ID it found. If those sit at the scan
bounds, widen them.

The client stops any Lua call that runs over 1000 ms, so the snapshot is done a slice at a time.
Each Logic tick (50 a second) does `WORK_PER_TICK` units of work, and the whole snapshot takes a
few seconds. Requests are only started from the `Logic` tick, never from inside another
request's callback, and each body is kept alive until its request finishes. Earlier versions
that chained requests from callbacks crashed the client (see `docs/api-concepts.md`).
Values are read over that time, so the snapshot isn't from a single instant. Anything that
changes meanwhile also shows up in `changes.jsonl`. Vars whose type the API can't convert get
`"error": "unsupported ValueType"`. Their value isn't read, which avoids an `[ERROR]` per var in
the console.

## Why it isn't for submission

It needs `httpAccess` to a localhost URL, and a dump of every var is a research tool rather than
a player feature. Moderation could see it as revealing hidden state. Keep it in dev.
