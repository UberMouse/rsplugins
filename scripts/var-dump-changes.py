#!/usr/bin/env python3
"""Print a var-dump change log in order, with the VarBits each base-var change moved.

Usage: python3 -I scripts/var-dump-changes.py [options]

  --changes PATH   the VarTransmit log (default: <repo>/dumps/var-dump/changes.jsonl)
  --catalog PATH   the var catalog with VarBit layout (default: <repo>/docs/vars/vars.csv)
  --after SEQ      only changes after this seq (the "last seq" a previous run printed)
  --last-session   only the newest session (the var-dump plugin restarts seq at each load)
  --match REGEX    only changes whose var, or a VarBit that moved, matches REGEX
  --all            keep timers and UI churn (dropped by default, see NOISE)

This is the probe tool for finding a chore's done flag: note the "last seq", do the chore in
game, then rerun with --after. A VarTransmit can name a base var rather than the VarBit that
changed (docs/api-concepts.md), so each base-var change is unpacked into the VarBits that moved.

Values that could identify other players are never printed, as in var-dump-analyze.py:
PLAYER_UID vars and every string value show only that they changed.
"""

import argparse
import csv
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Prefixes of vars that change constantly (clocks, timers, interface state) and drown a probe.
NOISE = (
    "DNDTRACKER_MINS", "DNDTRACKER_SINKHOLES_START", "DNDTRACKER_FAMIL", "DNDTRACKER_BIGCHIN",
    "CLOCK_TIME", "DOUBLEXP_PERM1", "CHAT_V3", "PAGEPOS", "MAKEX2012", "MTX", "MAXLIFEPOINTS",
    "PRAYER_BASE", "PLAYER_KIT", "TELEMETRY", "MUSIC_V3", "COMBATV2", "PLAYER_COORD",
    "TOPLEVEL", "CURSE_PERM", "LEAGUE_CURRENT", "QUICK_TELE", "RAND_TEMP",
)
REDACTED_TYPES = {"PLAYER_UID"}


def load_catalog(path):
    """Return ({base name: [(varbit, lo, hi)]}, {var name: type})."""
    bits, types = {}, {}
    with open(path, newline="") as f:
        for row in csv.DictReader(f):
            types[row["name"]] = row["type"]
            if row["base_var"] and row["bits"]:
                lo, hi = (int(b) for b in row["bits"].split("-"))
                bits.setdefault(row["base_var"], []).append((row["name"], lo, hi))
    return bits, types


def field(value, lo, hi):
    """Bits lo..hi of a 32-bit var value (negative values are bit 31 set)."""
    return ((value & 0xFFFFFFFF) >> lo) & ((1 << (hi - lo + 1)) - 1)


def read_jsonl(path):
    """Parsed lines of a JSONL file; a torn line (the receiver may be mid-append) or a line
    that isn't an object is skipped. Sibling of read_jsonl in var-dump-analyze.py."""
    rows = []
    with open(path) as f:
        for number, line in enumerate(f, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                row = None
            if not isinstance(row, dict):
                print(f"{path}:{number}: skipping line that is not a JSON object", file=sys.stderr)
                continue
            rows.append(row)
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--changes", default=ROOT / "dumps/var-dump/changes.jsonl")
    p.add_argument("--catalog", default=ROOT / "docs/vars/vars.csv")
    p.add_argument("--after", type=int, default=None)
    p.add_argument("--last-session", action="store_true")
    p.add_argument("--match", type=re.compile, default=None)
    p.add_argument("--all", action="store_true")
    args = p.parse_args()

    bits, types = load_catalog(args.catalog)
    rows = read_jsonl(args.changes)
    if args.last_session:
        # seq restarts with each plugin load, so a seq not above the last starts a session. A
        # retried batch the receiver already wrote (reply lost) therefore reads as a restart.
        start = 0
        for i in range(1, len(rows)):
            if rows[i]["seq"] <= rows[i - 1]["seq"]:
                start = i
        rows = rows[start:]

    last = None
    for e in rows:
        last = e["seq"] if last is None else max(last, e["seq"])
        name, old, new = e.get("name", ""), e.get("old"), e.get("new")
        if args.after is not None and e["seq"] <= args.after:
            continue
        if old == new or (not args.all and name.startswith(NOISE)):
            continue
        moved = []
        if isinstance(old, int) and isinstance(new, int):
            moved = [(b, lo, hi) for b, lo, hi in bits.get(name, [])
                     if field(old, lo, hi) != field(new, lo, hi)]
        if args.match and not (args.match.search(name)
                               or any(args.match.search(b) for b, _, _ in moved)):
            continue
        if types.get(name) in REDACTED_TYPES or isinstance(old, str) or isinstance(new, str):
            print(e["seq"], e["tick"], e["domain"], e["id"], name, "<changed, value hidden>")
            continue
        print(e["seq"], e["tick"], e["domain"], e["id"], name, old, "->", new)
        for b, lo, hi in moved:
            if types.get(b) in REDACTED_TYPES:
                print(f"    {b} [{lo}-{hi}] <changed, value hidden>")
            else:
                print(f"    {b} [{lo}-{hi}] {field(old, lo, hi)} -> {field(new, lo, hi)}")
    print("last seq", last)


if __name__ == "__main__":
    main()
