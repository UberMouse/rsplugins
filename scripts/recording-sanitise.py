#!/usr/bin/env python3
"""Turn a dev-recorder session into a test fixture: sanitised, and trimmed to a tick window.

Usage: scripts/recording-sanitise.py SESSION.jsonl OUT.jsonl --from T --to T
           [--placeholder "Fixture Player"]

SESSION is a file the receiver wrote (dumps/recordings/<plugin>/<time>-<session>.jsonl). The
format is in docs/testing.md ("Recordings"); turning a session into a fixture is described
there too ("Turning a session into a fixture").

- The player's display name, taken from the recording's own Player.GetEntity().displayName
  reads, becomes the placeholder in every string: read values, chat sender fields, and inside
  any other text. It matches case-insensitively, and a space, underscore, hyphen or no-break
  space in the name matches any of those.
- A chat message with a non-empty sender (one a player sent) has its text and its sender
  fields replaced by "<redacted>".
- Object text loses its memory address (`sol.jag::InventoryProxy: 0x591c...` becomes
  `sol.jag::InventoryProxy`, as the recorder now writes it), and a read that then repeats the
  last value of its path is dropped.
- Only entries with FROM <= t <= TO are kept, rebased so that FROM is t = 0. What the plugin
  knew before FROM is carried in at t = 0: the latest read of each path, the latest check of
  each permission, and for each PersistentDB key one Get of the value it held at FROM. Events
  and HTTP entries before FROM are dropped.

Nothing here prints the display name. The output is checked for it before the script exits.
"""

import argparse
import json
import re
import sys
from pathlib import Path

SCHEMA = 1
NAME_PATH = "Player.GetEntity().displayName"
ADDRESS = re.compile(r": 0x[0-9a-fA-F]+$")
SENDER_FIELDS = ("senderNameUnfiltered", "senderNameFiltered", "senderNameSimple")
REDACTED = "<redacted>"
# A space in a display name can show up as any of these, depending on where it is printed.
SPACES = " _- "


def walk(value, fix):
    """`value` with `fix` applied to every string in it, dict keys included."""
    if isinstance(value, str):
        return fix(value)
    if isinstance(value, list):
        return [walk(v, fix) for v in value]
    if isinstance(value, dict):
        return {fix(k): walk(v, fix) for k, v in value.items()}
    return value


def name_pattern(names):
    """A regex matching any of `names`, case-insensitively, with spaces interchangeable."""
    alternatives = []
    for name in sorted(names, key=len, reverse=True):
        alternatives.append("".join(
            f"[{re.escape(SPACES)}]" if c in SPACES else re.escape(c) for c in name))
    return re.compile("|".join(alternatives), re.IGNORECASE)


def strip_address(text):
    return ADDRESS.sub("", text)


def redact_player_chat(entry):
    """Redact a ChatMessage a player sent. Returns True if it was one."""
    payload, op = entry.get("payload") or {}, entry.get("op") or {}
    if not (any(payload.get(f) for f in SENDER_FIELDS) or op.get("sender")):
        return False
    for field in SENDER_FIELDS + ("chatMessage",):
        if field in payload:
            payload[field] = REDACTED
    for field in ("message", "sender"):
        if field in op:
            op[field] = REDACTED
    return True


def dedup_reads(entries):
    """Drop reads that repeat the previous value of their path (after a `dropped` gap, the
    recorder records a value again, so the comparison starts over)."""
    last, out = {}, []
    for e in entries:
        if e.get("k") == "dropped":
            last.clear()
        elif e.get("k") == "read":
            text = json.dumps(e.get("v"), sort_keys=True)
            if last.get(e.get("path")) == text:
                continue
            last[e.get("path")] = text
        out.append(e)
    return out


def carried_state(before):
    """The entries, all at t = 0, that carry what the plugin knew before the window."""
    reads, perms, db = {}, {}, {}
    for e in before:
        k = e.get("k")
        if k == "read":
            reads.pop(e["path"], None)  # re-inserted, so the order is that of the latest reads
            reads[e["path"]] = e
        elif k == "perm":
            perms.pop(e["permission"], None)
            perms[e["permission"]] = e
        elif k == "db":
            op, key = e.get("op", ""), e.get("key")
            if op == "Clear":
                db = {name: None for name in db}
            elif key is None:
                continue
            elif op == "Delete":
                db[key] = None
            elif op.startswith("Get") and "v" in e:
                db[key] = (op, e["v"])
            elif op == "Get":
                db[key] = None  # a plain Get that found nothing: the key was unset
            elif op.startswith("Set") and e.get("v") is True:
                db[key] = ("Get" + op[3:], e.get("value"))
    out = [{**e, "t": 0} for e in list(reads.values()) + list(perms.values())]
    for key, held in db.items():
        entry = {"t": 0, "k": "db", "op": "Get", "key": key}
        if held is not None:
            entry["op"], entry["v"] = held
        out.append(entry)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("session", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--from", dest="start", type=int, required=True, metavar="T")
    parser.add_argument("--to", dest="end", type=int, required=True, metavar="T")
    parser.add_argument("--placeholder", default="Fixture Player")
    args = parser.parse_args()
    if args.end < args.start:
        sys.exit("--to is before --from")

    lines = [json.loads(line) for line in args.session.read_text().splitlines() if line.strip()]
    if not lines or lines[0].get("k") != "session" or lines[0].get("schema") != SCHEMA:
        sys.exit(f"{args.session}: not a schema {SCHEMA} recording (no session header)")
    header, entries = lines[0], lines[1:]

    names = {e["v"] for e in entries
             if e.get("k") == "read" and e.get("path") == NAME_PATH and isinstance(e.get("v"), str)}
    if not names:
        sys.exit(f"{args.session}: no {NAME_PATH} read, so the display name can't be found")
    pattern = name_pattern(names)

    replaced = 0

    def fix(text):
        nonlocal replaced
        text, n = pattern.subn(args.placeholder, strip_address(text))
        replaced += n
        return text

    entries = dedup_reads([walk(e, strip_address) for e in entries])
    before = [e for e in entries if isinstance(e.get("t"), int) and e["t"] < args.start]
    window = [e for e in entries
              if isinstance(e.get("t"), int) and args.start <= e["t"] <= args.end]
    out = carried_state(before)
    redacted = 0
    for e in window:
        e = {**e, "t": e["t"] - args.start}
        if e.get("k") == "event" and e.get("name") == "ChatMessage":
            redacted += redact_player_chat(e)
        out.append(e)
    out = [walk(e, fix) for e in out]
    header = walk({**header, "window": [args.start, args.end]}, fix)

    text = "".join(json.dumps(e) + "\n" for e in [header] + out)
    if pattern.search(text):
        sys.exit("the display name is still in the output; nothing written")
    args.out.write_text(text)
    print(f"wrote {len(out)} entries ({len(text)} bytes) to {args.out}: ticks "
          f"{args.start}..{args.end} as 0..{args.end - args.start}, display name replaced in "
          f"{replaced} places, {redacted} player chat messages redacted")


if __name__ == "__main__":
    main()
