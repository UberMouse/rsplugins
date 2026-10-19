#!/usr/bin/env python3
"""Receive dumps from the var-dump plugin and write them to disk.

Usage: scripts/var-dump-receiver.py [output dir]   (default: dumps/var-dump)

Listens on 127.0.0.1:8765 (the plugin's "sink" URL) for:
  POST /snapshot  one part of a full snapshot; part 1 starts a new
                  snapshot-<time>.jsonl file, one var per line
  POST /changes   a batch of VarTransmit events, appended to changes.jsonl
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HOST, PORT = "127.0.0.1", 8765

out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else "dumps/var-dump")
current_snapshot = None  # path of the snapshot file parts are being added to


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        global current_snapshot
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            payload = json.loads(raw)
        except (json.JSONDecodeError, UnicodeDecodeError) as err:
            print(f"bad JSON on {self.path}: {err}; {len(raw)} bytes, starts {raw[:80]!r}")
            return self.reply(400)

        received = time.time()
        if self.path == "/snapshot":
            if payload["part"] == 1:
                stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(received))
                current_snapshot = out_dir / f"snapshot-{stamp}.jsonl"
                print(f"snapshot: {payload['totalVars']} vars -> {current_snapshot}")
            if current_snapshot is None:
                print("snapshot part arrived without part 1; ignoring")
                return self.reply(409)
            with current_snapshot.open("a") as f:
                for entry in payload["vars"]:
                    f.write(json.dumps(entry) + "\n")
            print(f"  part {payload['part']}/{payload['totalParts']}")
        elif self.path == "/changes":
            with (out_dir / "changes.jsonl").open("a") as f:
                for change in payload["changes"]:
                    change["received"] = received
                    f.write(json.dumps(change) + "\n")
            for change in payload["changes"]:
                print(f"change {change.get('domain')}.{change.get('name')}: "
                      f"{change.get('old')!r} -> {change.get('new')!r}")
        else:
            return self.reply(404)
        self.reply(200)

    def reply(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass  # the per-request access log is noise; we print our own summary


if __name__ == "__main__":
    sys.stdout.reconfigure(line_buffering=True)  # show output promptly even when piped
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"listening on http://{HOST}:{PORT}, writing to {out_dir}/")
    HTTPServer((HOST, PORT), Handler).serve_forever()
