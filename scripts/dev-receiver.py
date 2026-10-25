#!/usr/bin/env python3
"""Receive recordings from the dev recorder (lib/dev/recorder.lua) and write them to disk.

Usage: scripts/dev-receiver.py [--port 8766] [--out dumps/recordings]

Listens on 127.0.0.1 (the plugin's "recorder" URL) for POST /record, a batch:
  {"schema": 1, "plugin": "...", "session": "...", "seq": n, "dropped": n, "entries": [...]}

Each plugin enable is one session, written to <out>/<plugin>/<time>-<session>.jsonl: a
header line {"k": "session", ...}, then one entry per line in the order they arrive. When the
batch's cumulative `dropped` count has grown, a {"k": "dropped", "n": ...} line marks the gap
first. The format is documented in docs/testing.md ("Recordings"). A malformed batch gets a
400 (a body over MAX_BODY, a 413) and nothing is written.
"""

import argparse
import json
import re
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOST = "127.0.0.1"
# Plugin and session names become path parts. A leading letter or digit rules out "." and "..".
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")  # used with fullmatch
# Well above the recorder's 256 KB batches; a bigger body is refused unread.
MAX_BODY = 2 * 1024 * 1024


class Session:
    def __init__(self, path, seq):
        self.path, self.seq, self.dropped = path, seq, 0


sessions = {}  # (plugin, session) -> Session


def session_for(out_dir, batch):
    """The open session for a batch, starting a new file for a new enable.

    A session whose seq goes back down is a new enable that happened to get the same
    session name, so it gets a new file too.
    """
    key = (batch["plugin"], batch["session"])
    current = sessions.get(key)
    if current is None or batch["seq"] <= current.seq:
        stamp = time.strftime("%Y%m%d-%H%M%S")
        folder = out_dir / batch["plugin"]
        folder.mkdir(parents=True, exist_ok=True)
        path, n = folder / f"{stamp}-{batch['session']}.jsonl", 1
        while path.exists():  # a quick re-enable can land in the same second
            n += 1
            path = folder / f"{stamp}-{batch['session']}-{n}.jsonl"
        current = Session(path, batch["seq"])
        sessions[key] = current
        header = {"k": "session", "schema": batch["schema"], "plugin": batch["plugin"],
                  "session": batch["session"], "started": time.time()}
        with current.path.open("a") as f:
            f.write(json.dumps(header) + "\n")
        print(f"{batch['plugin']}: new session -> {current.path}")
    current.seq = batch["seq"]
    return current


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def batch_error(batch):
    """Why a decoded batch can't be written, or None if it can."""
    if not isinstance(batch, dict):
        return "not a JSON object"
    for key in ("plugin", "session"):
        if not isinstance(batch.get(key), str) or not SAFE_NAME.fullmatch(batch[key]):
            return f"bad {key} name {batch.get(key)!r}"
    for key in ("schema", "seq"):
        if not is_int(batch.get(key)):
            return f"{key} is not an integer"
    if not is_int(batch.get("dropped", 0)):
        return "dropped is not an integer"
    entries = batch.get("entries")
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        return "entries is not a list of objects"
    return None


def ordered(entry):
    """The entry with t and k first, so the file reads well."""
    head = {key: entry[key] for key in ("t", "k") if key in entry}
    return {**head, **entry}


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        if self.path != "/record":
            return self.reply(404)
        # A missing or negative length would block this single-threaded server in read().
        length = self.headers.get("Content-Length", "")
        if not (length.isascii() and length.isdigit()):
            print(f"bad Content-Length: {length!r}")
            return self.reply(400)
        if int(length) > MAX_BODY:
            print(f"batch of {length} bytes is over the {MAX_BODY}-byte cap")
            return self.reply(413)
        raw = self.rfile.read(int(length))
        try:
            # Game text isn't always valid UTF-8, and one bad byte shouldn't lose a batch.
            batch = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError as err:
            print(f"bad batch: {err!r}; {len(raw)} bytes, starts {raw[:80]!r}")
            return self.reply(400)
        error = batch_error(batch)
        if error:
            print(f"bad batch: {error}")
            return self.reply(400)
        entries = batch["entries"]

        session = session_for(self.server.out_dir, batch)
        lost = batch.get("dropped", 0) - session.dropped
        with session.path.open("a") as f:
            if lost > 0:
                first_t = entries[0].get("t") if entries else None
                f.write(json.dumps({"t": first_t, "k": "dropped", "n": lost}) + "\n")
                session.dropped = batch["dropped"]
            for entry in entries:
                f.write(json.dumps(ordered(entry)) + "\n")
        note = f", {lost} dropped before it" if lost > 0 else ""
        print(f"{batch['plugin']} {batch['session']}: batch {batch['seq']}, "
              f"{len(entries)} entries{note}")
        self.reply(200)

    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass  # the per-request access log is noise; we print our own line per batch


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8766)
    parser.add_argument("--out", type=Path, default=Path("dumps/recordings"))
    args = parser.parse_args()
    sys.stdout.reconfigure(line_buffering=True)  # show output promptly even when piped
    args.out.mkdir(parents=True, exist_ok=True)
    server = HTTPServer((HOST, args.port), Handler)
    server.out_dir = args.out
    print(f"listening on http://{HOST}:{args.port}/record, writing to {args.out}/")
    server.serve_forever()


if __name__ == "__main__":
    main()
