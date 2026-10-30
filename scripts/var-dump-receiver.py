#!/usr/bin/env python3
"""Receive dumps from the var-dump plugin and write them to disk.

Usage: scripts/var-dump-receiver.py [output dir]   (default: <repo>/dumps/var-dump)

Listens on 127.0.0.1:8765 (the plugin's "sink" URL) for:
  POST /snapshot  one part of a full snapshot; part 1 starts a new
                  snapshot-<time>.jsonl.partial file, one var per line, renamed to
                  .jsonl when the last part arrives (so a snapshot the plugin
                  abandoned mid-upload never looks like a complete one)
  POST /changes   a batch of VarTransmit events, appended to changes.jsonl
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HOST, PORT = "127.0.0.1", 8765

out_dir = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "dumps/var-dump")
current_snapshot = None  # path of the snapshot file parts are being added to


def local_name(value):
    """The hostname of a Host header or Origin URL, or None if it has none."""
    return urlsplit(value if "//" in value else "//" + value).hostname


class Handler(BaseHTTPRequestHandler):
    def refused(self):
        """Whether to refuse this request as one a browser sent (a 403 is already replied).

        A web page can POST to 127.0.0.1 without a preflight, and DNS rebinding can point
        another hostname at it, so binding to loopback alone doesn't keep pages out. The
        plugin's HTTP client sends no Origin (docs/api-concepts.md) and a loopback Host."""
        host = self.headers.get("Host")
        if host is None or local_name(host) not in ("127.0.0.1", "localhost"):
            print(f"refused {self.path}: Host {host!r}")
            return self.reply(403) or True
        origin = self.headers.get("Origin")
        if origin is not None and local_name(origin) not in ("127.0.0.1", "localhost"):
            print(f"refused {self.path}: Origin {origin!r}")
            return self.reply(403) or True
        return False

    def do_POST(self):
        global current_snapshot
        if self.refused():
            return
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length)
        try:
            # Game text isn't always valid UTF-8, and one bad byte shouldn't lose a part.
            payload = json.loads(raw.decode("utf-8", errors="replace"))
        except json.JSONDecodeError as err:
            print(f"bad JSON on {self.path}: {err}; {len(raw)} bytes, starts {raw[:80]!r}")
            return self.reply(400)

        received = time.time()
        if self.path == "/snapshot":
            if payload["part"] == 1:
                stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(received))
                # An earlier .partial (abandoned upload) stays on disk; analyze ignores it.
                current_snapshot = out_dir / f"snapshot-{stamp}.jsonl.partial"
                current_snapshot.unlink(missing_ok=True)  # same-second restart: don't append
                print(f"snapshot: {payload['totalVars']} vars -> {current_snapshot}")
            if current_snapshot is None:
                print("snapshot part arrived without part 1; ignoring")
                return self.reply(409)
            with current_snapshot.open("a") as f:
                for entry in payload["vars"]:
                    f.write(json.dumps(entry) + "\n")
            print(f"  part {payload['part']}/{payload['totalParts']}")
            if payload["part"] == payload["totalParts"]:
                final = current_snapshot.with_suffix("")  # drop ".partial"
                current_snapshot.rename(final)
                current_snapshot = None
                print(f"snapshot complete: {final}")
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
