#!/usr/bin/env python3
"""Turn a dev-recorder session into a test fixture: sanitised, and trimmed to a tick window.

Usage: scripts/recording-sanitise.py SESSION.jsonl OUT.jsonl --from T --to T
           [--placeholder "Fixture Player"] [--allow-dropped] [--short-name-ok]

SESSION is a file the receiver wrote (dumps/recordings/<plugin>/<time>-<session>.jsonl). The
format is in docs/testing.md ("Recordings"); turning a session into a fixture is described
there too ("Turning a session into a fixture").

- The player's display name, taken from the recording's own Player.GetEntity().displayName
  reads, becomes the placeholder in every string: read values, chat sender fields, and inside
  any other text. It matches case-insensitively as a substring, and a space, underscore,
  hyphen or no-break space in the name matches any of those. A name under 4 characters would
  also match inside unrelated words, so it needs --short-name-ok.
- A chat message with a non-empty sender (one a player sent) has its text and its sender
  fields replaced by "<redacted>".
- A chat message with no sender (game text) keeps its text only if it fully matches a line
  of scripts/recording-chat-allowlist.txt. Otherwise its text becomes "<redacted:N chars>",
  N its length in characters, and its chatType is kept.
- Object text loses its memory address (`sol.jag::InventoryProxy: 0x591c...` becomes
  `sol.jag::InventoryProxy`, as the recorder now writes it), and a read that then repeats the
  last value of its path is dropped.
- Only entries with FROM <= t <= TO are kept, rebased so that FROM is t = 0. What the plugin
  knew before FROM is carried in at t = 0: the latest read of each path, the latest check of
  each permission, and for each PersistentDB key one Get of the value it held at FROM. Events
  and HTTP entries before FROM are dropped.
- A `dropped` line (entries the recorder lost) at or before TO is refused unless
  --allow-dropped: in the window it is a gap in the replay, and before it the carried state
  may be wrong. Allowed, the window's are kept and the earlier ones become one at t = 0, so
  the replay must allow them too.

Nothing here prints the display name. The output is checked for it, as text and as every
string it decodes to, before it is written and again as read back from disk; if the name is
found, the script exits non-zero and leaves none of its output on disk.
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
SHORT_NAME = 4
ALLOWLIST = Path(__file__).with_name("recording-chat-allowlist.txt")


class Refused(Exception):
    """The session can't be made into a fixture as asked; the message says why."""


def walk(value, fix):
    """`value` with `fix` applied to every string in it, dict keys included."""
    if isinstance(value, str):
        return fix(value)
    if isinstance(value, list):
        return [walk(v, fix) for v in value]
    if isinstance(value, dict):
        return {fix(k): walk(v, fix) for k, v in value.items()}
    return value


def strings(value):
    """Every string in `value`, dict keys included."""
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)
    elif isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from strings(v)


def name_pattern(names):
    """A regex matching any of `names`, case-insensitively, with spaces interchangeable."""
    alternatives = []
    for name in sorted(names, key=len, reverse=True):
        alternatives.append("".join(
            f"[{re.escape(SPACES)}]" if c in SPACES else re.escape(c) for c in name))
    return re.compile("|".join(alternatives), re.IGNORECASE)


def replace_name(text, pattern, placeholder):
    """`text` with the display name replaced, and how many times it was."""
    return pattern.subn(placeholder, text)


def leaks(pattern, text):
    """How often the name shows up in `text`, a JSON-lines document: in the text as written,
    and in every string its lines decode to, so a name written with escapes (\\u00eb) counts."""
    found = len(pattern.findall(text))
    for line in text.splitlines():
        if line.strip():
            found += sum(len(pattern.findall(s)) for s in strings(json.loads(line)))
    return found


def load_allowlist(path):
    """The game-chat patterns in `path`: one regex per line, `#` comments and blank lines
    skipped. Each must be anchored with ^ and $, so it can only match a whole message."""
    patterns = []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        if not (line.startswith("^") and line.endswith("$")):
            raise Refused(f"{path}:{n}: a pattern must start with ^ and end with $")
        patterns.append(re.compile(line))
    return patterns


def strip_address(text):
    return ADDRESS.sub("", text)


def redact_chat(entry, allowlist):
    """Redact a ChatMessage: all of a player's, and game text the allowlist doesn't match.
    Returns "player", "game" (redacted) or "kept"."""
    payload, op = entry.get("payload") or {}, entry.get("op") or {}
    if any(payload.get(f) for f in SENDER_FIELDS) or op.get("sender"):
        for field in SENDER_FIELDS + ("chatMessage",):
            if field in payload:
                payload[field] = REDACTED
        for field in ("message", "sender"):
            if field in op:
                op[field] = REDACTED
        return "player"
    texts = [t for t in (payload.get("chatMessage"), op.get("message")) if t is not None]
    if texts and all(isinstance(t, str) and any(p.fullmatch(t) for p in allowlist)
                     for t in texts):
        return "kept"
    for holder, field in ((payload, "chatMessage"), (op, "message")):
        if isinstance(holder.get(field), str):
            holder[field] = f"<redacted:{len(holder[field])} chars>"
    return "game"


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


def sanitise(lines, start, end, placeholder, allowlist, allow_dropped=False,
             short_name_ok=False):
    """The fixture's text for the recording `lines` (decoded JSON lines, header first), the
    name pattern to check it with, and counts of what was done. Raises Refused."""
    if not lines or lines[0].get("k") != "session" or lines[0].get("schema") != SCHEMA:
        raise Refused(f"not a schema {SCHEMA} recording (no session header)")
    header, entries = lines[0], lines[1:]

    names = {e["v"] for e in entries
             if e.get("k") == "read" and e.get("path") == NAME_PATH and isinstance(e.get("v"), str)}
    if not names:
        raise Refused(f"no {NAME_PATH} read, so the display name can't be found")
    if not short_name_ok and min(len(n) for n in names) < SHORT_NAME:
        raise Refused(f"the display name is under {SHORT_NAME} characters, so replacing it as a "
                      "substring would change unrelated text; check the output by hand and pass "
                      "--short-name-ok")
    pattern = name_pattern(names)

    timed = [e for e in entries if isinstance(e.get("t"), int)]
    drops = [e for e in timed if e.get("k") == "dropped" and e["t"] <= end]
    if drops and not allow_dropped:
        raise Refused(f"the recorder lost {sum(e.get('n') or 0 for e in drops)} entries in "
                      f"{len(drops)} gap(s) at or before --to (first at t={drops[0]['t']}); "
                      "pick a window after them, or pass --allow-dropped")

    stats = {"replaced": 0, "player": 0, "game": 0, "kept": 0}

    def fix(text):
        text, n = replace_name(strip_address(text), pattern, placeholder)
        stats["replaced"] += n
        return text

    entries = dedup_reads([walk(e, strip_address) for e in entries])
    before = [e for e in entries if isinstance(e.get("t"), int) and e["t"] < start]
    window = [e for e in entries if isinstance(e.get("t"), int) and start <= e["t"] <= end]
    out = carried_state(before)
    lost_before = sum(e.get("n") or 0 for e in before if e.get("k") == "dropped")
    if lost_before:
        out.insert(0, {"t": 0, "k": "dropped", "n": lost_before})
    for e in window:
        e = {**e, "t": e["t"] - start}
        if e.get("k") == "event" and e.get("name") == "ChatMessage":
            stats[redact_chat(e, allowlist)] += 1
        out.append(e)
    out = [walk(e, fix) for e in out]
    header = walk({**header, "window": [start, end]}, fix)
    stats["entries"] = len(out)
    text = "".join(json.dumps(e, ensure_ascii=False) + "\n" for e in [header] + out)
    return text, pattern, stats


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("session", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--from", dest="start", type=int, required=True, metavar="T")
    parser.add_argument("--to", dest="end", type=int, required=True, metavar="T")
    parser.add_argument("--placeholder", default="Fixture Player")
    parser.add_argument("--allow-dropped", action="store_true")
    parser.add_argument("--short-name-ok", action="store_true")
    args = parser.parse_args()
    if args.end < args.start:
        sys.exit("--to is before --from")

    lines = [json.loads(line) for line in args.session.read_text(encoding="utf-8").splitlines()
             if line.strip()]
    try:
        text, pattern, stats = sanitise(lines, args.start, args.end, args.placeholder,
                                        load_allowlist(ALLOWLIST), args.allow_dropped,
                                        args.short_name_ok)
    except Refused as e:
        sys.exit(f"{args.session}: {e}")

    if leaks(pattern, text):
        sys.exit("the display name is still in the output; nothing written")
    args.out.write_text(text, encoding="utf-8")
    if leaks(pattern, args.out.read_text(encoding="utf-8")):
        args.out.unlink()
        sys.exit("the display name is in the written file; deleted it")
    size = len(text.encode("utf-8"))
    print(f"wrote {stats['entries']} entries ({size} bytes) to {args.out}: ticks "
          f"{args.start}..{args.end} as 0..{args.end - args.start}, display name replaced in "
          f"{stats['replaced']} places, chat redacted: {stats['player']} player, "
          f"{stats['game']} game ({stats['kept']} allowlisted game lines kept)")


if __name__ == "__main__":
    main()
