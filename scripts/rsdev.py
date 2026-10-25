#!/usr/bin/env python3
"""The dev daemon and CLI: the host end of the dev recorder and of the dev bridge.

Usage: scripts/rsdev.py daemon [--port 8766] [--out dumps]     run the daemon in the foreground
       scripts/rsdev.py start | stop | status                  manage a detached daemon
       scripts/rsdev.py exec <console command...> [--timeout 10]
       scripts/rsdev.py events [--since N] [--follow] [--name X]
       scripts/rsdev.py eval <lua code...> | --file F | --reset [--timeout 10]
       scripts/rsdev.py logs [--since N] [--follow] [--plugin X] [--json]
       scripts/rsdev.py shot [--region WxH+X+Y] [--max 1600] [--count N --every S] [--delay S]
       scripts/rsdev.py exec <console command...> --shot [--shot-delay 1.0]

The daemon listens on 127.0.0.1 only, port 8766 (the plugins' "recorder" and "rsdev" URLs).

  POST /record       a batch from the dev recorder (lib/dev/recorder.lua):
    {"schema": 1, "plugin": "...", "session": "...", "seq": n, "dropped": n, "entries": [...]}
    Each plugin enable is one session, written to <out>/recordings/<plugin>/<time>-<session>.jsonl:
    a header line {"k": "session", ...}, then one entry per line in the order they arrive. When
    the batch's cumulative `dropped` count has grown, a {"k": "dropped", "n": ...} line marks the
    gap first. The format is documented in docs/testing.md ("Recordings"). A malformed batch gets
    a 400 (a body over MAX_BODY, a 413) and nothing is written.

  POST /bridge/sync  the dev-bridge plugin's poll (docs/dev-environment.md, "Dev bridge"): it
    sends its events and command results, and gets the queued commands back, one per line.

  POST /tee          log lines a plugin forwards (lib/dev/tee): {"schema": 1, "plugin": "...",
    "session": "...", "seq": n, "dropped": n, "lines": [{"t": n, "level": "...", "text": "..."}]}.
    Each line becomes a `Log` event in the same numbered stream as the bridge's, written to
    <out>/rsdev/events/tee/<plugin>/<session>.jsonl. A malformed body gets a 400 and nothing is
    applied.

  /cli/...           what the subcommands above talk to. Nothing else needs these.

Every console command queued through `exec` is logged with its id: the audit trail. So is every
`eval` and `reset`, an eval's Lua source cut to its first 200 characters.
"""

import argparse
import json
import math
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import deque
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from types import SimpleNamespace

HOST = "127.0.0.1"
DEFAULT_PORT = 8766
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "dumps"  # not cwd: the CLI works anywhere
# Plugin and session names become path parts. A leading letter or digit rules out "." and "..".
SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")  # used with fullmatch
CMD_ID = re.compile(r"[A-Za-z0-9_-]{1,32}")  # used with fullmatch
# Well above the recorder's 256 KB batches; a bigger body is refused unread.
MAX_BODY = 2 * 1024 * 1024
# Command kinds the bridge understands. The daemon only queues them; the plugin runs them.
KINDS = ("exec", "eval", "reset")
LOG_LEVELS = ("print", "log", "error")
AUDIT_SOURCE_CHARS = 200  # how much of an eval's source the daemon log keeps
RESULT_FIELDS = ("values", "nvalues", "output", "truncated")  # what an eval result may carry
MAX_EVENTS = 10_000  # events kept in memory; every one is also on disk
CONNECTED_WITHIN = 2.0  # seconds since the last sync that still counts as connected
MAX_WAIT = 120.0  # cap on how long one /cli request may block a thread
# The game window's WM_CLASS (instance, class). The title is never matched: a browser tab called
# "RuneScape - Vivaldi" has the same words in it.
CLIENT_WM_CLASS = ["rs2client", "RuneScape"]
# Always required; magick too unless --max 0. All come from the dev shell (flake.nix).
SHOT_TOOLS = ("maim", "xprop", "xwininfo")
MAX_SHOT_COUNT = 100
DEFAULT_SHOT_MAX = 1600  # --max default: longest side in pixels


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def escape_arg(text):
    """A command line's arg field: backslash, tab, newline and CR escaped, so it is one field."""
    return (
        text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
    )


def unescape_arg(text):
    """Inverse of escape_arg (the plugin does this in Lua; tests use it to check the round trip)."""
    table = {"\\": "\\", "t": "\t", "n": "\n", "r": "\r"}
    return re.sub(r"\\(.)", lambda m: table.get(m.group(1), m.group(0)), text)


class RecSession:
    def __init__(self, path, seq):
        self.path, self.seq, self.dropped = path, seq, 0


class Command:
    def __init__(self, cmd_id, kind, arg):
        self.id, self.kind, self.arg = cmd_id, kind, arg
        # queued -> delivered -> done, or queued -> withdrawn. Every move happens under State.cond.
        self.state = "queued"
        self.ok, self.error = None, None
        self.result = {}  # eval's values/nvalues/output/truncated, as the plugin sent them


class State:
    """Everything the handler threads share. One Condition guards all of it, and `exec` waits on
    it, so a sync that resolves a command wakes the waiting thread."""

    def __init__(self, out_dir):
        self.out_dir = out_dir
        self.cond = threading.Condition()
        self.rec_sessions = {}  # (plugin, session) -> RecSession
        self.bridge = None  # the last bridge session seen: dict, see sync()
        self.queue = deque()  # Commands not yet delivered, FIFO
        self.commands = {}  # id -> Command, for delivered ones awaiting a result
        self.cmd_count = 0
        self.events = deque(maxlen=MAX_EVENTS)
        self.last_n = 0  # n of the newest event
        self.total_dropped = 0
        self.tee_dropped = {}  # (plugin, session) -> the cumulative dropped count last seen
        self.run = secrets.token_hex(4)  # event numbers restart per daemon run; followers check it

    # --- recorder (POST /record) -------------------------------------------------------------

    def record(self, batch):
        """Write one validated recorder batch. Returns the log line to print."""
        entries = batch["entries"]
        with self.cond:
            session = self._rec_session(batch)
            lost = batch.get("dropped", 0) - session.dropped
            with session.path.open("a") as f:
                if lost > 0:
                    first_t = entries[0].get("t") if entries else None
                    f.write(json.dumps({"t": first_t, "k": "dropped", "n": lost}) + "\n")
                    session.dropped = batch["dropped"]
                for entry in entries:
                    f.write(json.dumps(ordered(entry)) + "\n")
        note = f", {lost} dropped before it" if lost > 0 else ""
        return (
            f"{batch['plugin']} {batch['session']}: batch {batch['seq']}, "
            f"{len(entries)} entries{note}"
        )

    def _rec_session(self, batch):
        """The open session for a batch, starting a new file for a new enable.

        A session whose seq goes back down is a new enable that happened to get the same
        session name, so it gets a new file too. Caller holds the lock.
        """
        key = (batch["plugin"], batch["session"])
        current = self.rec_sessions.get(key)
        if current is None or batch["seq"] <= current.seq:
            stamp = time.strftime("%Y%m%d-%H%M%S")
            folder = self.out_dir / "recordings" / batch["plugin"]
            folder.mkdir(parents=True, exist_ok=True)
            path, n = folder / f"{stamp}-{batch['session']}.jsonl", 1
            while path.exists():  # a quick re-enable can land in the same second
                n += 1
                path = folder / f"{stamp}-{batch['session']}-{n}.jsonl"
            current = RecSession(path, batch["seq"])
            self.rec_sessions[key] = current
            header = {
                "k": "session",
                "schema": batch["schema"],
                "plugin": batch["plugin"],
                "session": batch["session"],
                "started": time.time(),
            }
            with current.path.open("a") as f:
                f.write(json.dumps(header) + "\n")
            print(f"{batch['plugin']}: new session -> {current.path}")
        current.seq = batch["seq"]
        return current

    # --- bridge (POST /bridge/sync) ----------------------------------------------------------

    def sync(self, body):
        """Apply one validated sync and return the response body: the commands now delivered."""
        with self.cond:
            now = time.time()
            bridge = self.bridge
            if bridge is None or bridge["session"] != body["session"]:
                print(f"bridge: new session {body['session']} (plugin {body['plugin']})")
                # The old session can't report any more; don't leave its exec calls waiting.
                for cmd in list(self.commands.values()):
                    self._finish(cmd, False, "bridge restarted before reporting")
                bridge = self.bridge = {"session": body["session"], "dropped": 0, "hello": None}
            bridge.update(seq=body["seq"], seen=now)
            if body.get("hello") is not None:  # the plugin sends it every sync; keep the last
                bridge["hello"] = body["hello"]

            for result in body.get("results", []):
                cmd = self.commands.get(result["id"])
                if cmd is not None:
                    extra = {k: result[k] for k in RESULT_FIELDS if k in result}
                    self._finish(cmd, result["ok"], result.get("error", ""), extra)
                else:  # e.g. the late result of an exec that already gave up on it
                    print(f"ignored result for unknown command id {result['id']!r}")

            lost = body.get("dropped", 0) - bridge["dropped"]
            bridge["dropped"] = max(bridge["dropped"], body.get("dropped", 0))
            events = self._with_drop_marker(body.get("events", []), lost)
            self._add_events(f"{body['session']}.jsonl", body["session"], events)

            lines = []
            while self.queue:
                cmd = self.queue.popleft()
                cmd.state = "delivered"
                self.commands[cmd.id] = cmd
                lines.append(f"{cmd.id}\t{cmd.kind}\t{escape_arg(cmd.arg)}\n")
                print(f"delivered command {cmd.id}")
            return "".join(lines)

    def tee(self, body):
        """Apply one validated tee batch: each line becomes a Log event. Returns nothing."""
        with self.cond:
            key = (body["plugin"], body["session"])
            seen = self.tee_dropped.get(key, 0)
            self.tee_dropped[key] = max(seen, body.get("dropped", 0))
            events = [
                {
                    "t": line["t"],
                    "name": "Log",
                    "payload": {
                        "plugin": body["plugin"],
                        "level": line["level"],
                        "text": line["text"],
                    },
                }
                for line in body["lines"]
            ]
            lost = body.get("dropped", 0) - seen
            if lost > 0:
                # A Log event, not the bridge's bare marker: carrying the plugin is what lets
                # `logs` (and `logs --plugin X`) show which plugin lost lines.
                self.total_dropped += lost
                first_t = events[0]["t"] if events else None
                marker = {"plugin": body["plugin"], "level": "dropped", "text": f"{lost} lines lost"}
                events.insert(0, {"t": first_t, "name": "Log", "payload": marker})
            # A directory per plugin: a joined name could not tell plugin a-b/session c from a/b-c.
            self._add_events(Path("tee") / body["plugin"] / f"{body['session']}.jsonl", body["session"], events)

    def _with_drop_marker(self, events, lost):
        """`events`, led by a dropped marker if `lost` events never arrived. Caller holds the lock."""
        if lost > 0:
            first_t = events[0].get("t") if events else None
            self.total_dropped += lost
            events = [{"t": first_t, "name": "dropped", "n_lost": lost}, *events]
        return events

    def _finish(self, cmd, ok, error, result=None):
        """Resolve a delivered command. Caller holds the lock."""
        cmd.state, cmd.ok, cmd.error = "done", ok, error
        cmd.result = result or {}
        del self.commands[cmd.id]
        self.cond.notify_all()

    def _add_events(self, filename, session, events):  # filename: relative to <out>/rsdev/events
        """Number, keep and persist a sync's events. Caller holds the lock.

        One file open per sync: a login burst can be hundreds of events, and every handler thread
        and long poll waits on this lock.
        """
        if not events:
            return
        lines = []
        for event in events:
            self.last_n += 1
            # n and session last, so an event carrying its own keys can't override the numbering.
            stored = {**event, "n": self.last_n, "session": session}
            self.events.append(stored)
            lines.append(json.dumps(stored) + "\n")
        path = self.out_dir / "rsdev" / "events" / filename
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as f:
            f.write("".join(lines))
        self.cond.notify_all()  # wakes long-polling `events --follow` calls

    # --- CLI ---------------------------------------------------------------------------------

    def exec(self, text, timeout, kind="exec"):
        """Queue a command (`kind`: exec, eval or reset) and wait for its result.

        Returns {"outcome": ...}.

        Outcomes: ok / error (it ran, with the plugin's verdict), withdrawn (never delivered
        before the timeout, and now removed so it can never run), unknown (delivered, no result).
        """
        with self.cond:
            self.cmd_count += 1
            cmd = Command(f"c{self.cmd_count}-{secrets.token_hex(3)}", kind, text)
            self.queue.append(cmd)
            # Console commands are short and logged whole; Lua source is cut to keep the log readable.
            shown = text if kind == "exec" else text[:AUDIT_SOURCE_CHARS]
            more = f" (+{len(text) - len(shown)} more characters)" if len(shown) < len(text) else ""
            print(f"queued command {cmd.id}: {kind} {shown!r}{more}")
            deadline = time.monotonic() + timeout
            while cmd.state in ("queued", "delivered"):
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.cond.wait(left)
            if cmd.state == "queued":
                # Delivery moves state under this same lock, so it is either delivered or
                # withdrawn here, never both.
                self.queue.remove(cmd)
                cmd.state = "withdrawn"
                print(f"withdrew command {cmd.id}: not delivered in {timeout}s")
                return {"outcome": "withdrawn", "id": cmd.id}
            if cmd.state == "delivered":
                print(f"command {cmd.id} delivered but no result in {timeout}s")
                # Forget it, or a plugin that never reports would grow `commands` without bound.
                # A result that turns up later is ignored (see sync).
                del self.commands[cmd.id]
                return {"outcome": "unknown", "id": cmd.id}
            outcome = "ok" if cmd.ok else "error"
            return {"outcome": outcome, "id": cmd.id, "error": cmd.error or "", **cmd.result}

    def events_after(self, since, name, wait):
        """Events with n > since (filtered by name), waiting up to `wait` s for the first.

        Returns (events, last): `last` is the newest n seen, which a follower passes back as
        `since` even when the filter hid every event.
        """
        with self.cond:
            deadline = time.monotonic() + wait
            while self.last_n <= since:
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.cond.wait(left)
            found = [e for e in self.events if e["n"] > since]
            if name is not None:
                found = [e for e in found if e["name"] == name]
            return found, max(self.last_n, since)

    def status(self):
        with self.cond:
            b = self.bridge
            seen = None if b is None else round(time.time() - b["seen"], 3)
            return {
                "up": True,
                "pid": os.getpid(),  # lets `stop` confirm which process answers on the port
                # Lets the CLI refuse a kind an older daemon would queue as a console command.
                "kinds": list(KINDS),
                "bridge": None
                if b is None
                else {
                    "session": b["session"],
                    "seq": b["seq"],
                    "hello": b["hello"],
                    "seen_ago": seen,
                    "connected": seen <= CONNECTED_WITHIN,
                },
                "queued": len(self.queue),
                "awaiting_result": len(self.commands),
                "events": self.last_n,
                "dropped": self.total_dropped,
            }


def ordered(entry):
    """The entry with t and k first, so the file reads well."""
    head = {key: entry[key] for key in ("t", "k") if key in entry}
    return {**head, **entry}


def batch_error(batch):
    """Why a decoded recorder batch can't be written, or None if it can."""
    if not isinstance(batch, dict):
        return "not a JSON object"
    for key in ("plugin", "session"):
        if not isinstance(batch.get(key), str) or not SAFE_NAME.fullmatch(batch[key]):
            return f"bad {key} name {batch.get(key)!r}"
    for key in ("schema", "seq"):
        if not is_int(batch.get(key)):
            return f"{key} is not an integer"
    if batch["seq"] < 1:
        return "seq is under 1 (the recorder counts batches from 1)"
    if not is_int(batch.get("dropped", 0)):
        return "dropped is not an integer"
    if batch.get("dropped", 0) < 0:
        return "dropped is negative"
    entries = batch.get("entries")
    if not isinstance(entries, list) or not all(isinstance(e, dict) for e in entries):
        return "entries is not a list of objects"
    return None


def sync_error(body):
    """Why a decoded bridge sync can't be applied, or None if it can."""
    err = batch_error({**body, "entries": []}) if isinstance(body, dict) else "not a JSON object"
    if err:
        return err
    hello = body.get("hello")
    if hello is not None:
        env = hello.get("env") if isinstance(hello, dict) else None
        if not isinstance(env, dict) or not all(isinstance(v, str) for v in env.values()):
            return "hello.env is not an object of strings"
    events = body.get("events", [])
    if not isinstance(events, list):
        return "events is not a list"
    for e in events:
        if not isinstance(e, dict) or not isinstance(e.get("name"), str):
            return "an event is not an object with a string name"
        if "t" in e and e["t"] is not None and not isinstance(e["t"], (int, float)):
            return "an event's t is not a number"
    results = body.get("results", [])
    if not isinstance(results, list):
        return "results is not a list"
    for r in results:
        if not isinstance(r, dict) or not isinstance(r.get("id"), str):
            return "a result is not an object with a string id"
        if not isinstance(r.get("ok"), bool):
            return "a result's ok is not a boolean"
        if "error" in r and not isinstance(r["error"], str):
            return "a result's error is not a string"
        if "values" in r and not isinstance(r["values"], list):
            return "a result's values is not a list"
        if "nvalues" in r and not is_int(r["nvalues"]):
            return "a result's nvalues is not an integer"
        if "output" in r and not (
            isinstance(r["output"], list) and all(isinstance(s, str) for s in r["output"])
        ):
            return "a result's output is not a list of strings"
        if "truncated" in r and not isinstance(r["truncated"], bool):
            return "a result's truncated is not a boolean"
    return None


def tee_error(body):
    """Why a decoded tee batch can't be applied, or None if it can."""
    err = batch_error({**body, "entries": []}) if isinstance(body, dict) else "not a JSON object"
    if err:
        return err
    lines = body.get("lines")
    if not isinstance(lines, list):
        return "lines is not a list"
    for line in lines:
        if not isinstance(line, dict):
            return "a line is not an object"
        if not is_int(line.get("t")):
            return "a line's t is not an integer"
        if line.get("level") not in LOG_LEVELS:
            return f"a line's level is not one of {', '.join(LOG_LEVELS)}"
        if not isinstance(line.get("text"), str):
            return "a line's text is not a string"
    return None


class Handler(BaseHTTPRequestHandler):
    # Seconds a socket read may wait, so a client that sends less body than its Content-Length
    # can't hold a handler thread; the handler drops a timed-out connection. It does not limit
    # how long `exec` and `events --follow` block, which wait on a Condition, not the socket.
    timeout = 5

    def refused(self, route):
        """Whether to refuse this request as one a browser sent (a 403 is already replied).

        A web page can POST to 127.0.0.1 (a CORS "simple" request needs no preflight) and DNS
        rebinding can point a hostname at it, so a bind to loopback alone doesn't keep web pages
        out. A browser always sends Origin on a cross-origin POST and a Host that isn't ours when
        rebound; the CLI sends no Origin. /cli/* also needs the custom header X-Rsdev, which
        makes a browser preflight first, and the daemon never answers a preflight with CORS
        headers. The log line names the route and header, to show what a client library sends.
        """
        host = self.headers.get("Host")
        port = self.server.server_address[1]
        if host not in (f"{HOST}:{port}", f"localhost:{port}"):
            print(f"refused {route}: Host {host!r}")
            return self.reply(403) or True
        if "Origin" in self.headers:
            print(f"refused {route}: Origin {self.headers['Origin']!r}")
            return self.reply(403) or True
        if route.startswith("/cli/") and self.headers.get("X-Rsdev") != "1":
            print(f"refused {route}: no X-Rsdev header")
            return self.reply(403) or True
        return False

    def do_POST(self):
        route = urllib.parse.urlsplit(self.path).path
        if self.refused(route):
            return None
        if route not in ("/record", "/bridge/sync", "/tee", "/cli/exec"):
            return self.reply(404)
        # A missing or negative length would leave read() waiting on the client, and int()
        # raises on a digit string thousands long, hence the 10-digit cap before it.
        length = self.headers.get("Content-Length", "")
        if not (length.isascii() and length.isdigit() and len(length) <= 10):
            print(f"bad Content-Length: {length[:20]!r} ({len(length)} characters)")
            return self.reply(400)
        if int(length) > MAX_BODY:
            print(f"body of {length} bytes is over the {MAX_BODY}-byte cap")
            return self.reply(413)
        raw = self.rfile.read(int(length))
        try:
            # Game text isn't always valid UTF-8, and one bad byte shouldn't lose a batch.
            body = json.loads(raw.decode("utf-8", errors="replace"))
        except (ValueError, RecursionError) as err:  # JSONDecodeError, int past the digit limit; deep nesting
            print(f"bad {route} body: {err!r}; {len(raw)} bytes, starts {raw[:80]!r}")
            return self.reply(400)
        state = self.server.state
        if route == "/record":
            error = batch_error(body)
            if error:
                print(f"bad batch: {error}")
                return self.reply(400)
            print(state.record(body))
            return self.reply(200)
        if route == "/bridge/sync":
            error = sync_error(body)
            if error:
                print(f"bad sync: {error}")
                return self.reply(400)
            return self.reply(200, state.sync(body).encode(), "text/plain; charset=utf-8")
        if route == "/tee":
            error = tee_error(body)
            if error:
                print(f"bad tee batch: {error}")
                return self.reply(400)
            state.tee(body)
            return self.reply(200)
        # /cli/exec: `command` is the console command or Lua source; a reset takes none.
        timeout = body.get("timeout") if isinstance(body, dict) else None
        kind = body.get("kind", "exec") if isinstance(body, dict) else None
        text = body.get("command", "") if isinstance(body, dict) else None
        if kind not in KINDS or not isinstance(text, str) or (text == "") != (kind == "reset"):
            return self.reply(400)
        if isinstance(timeout, bool) or not isinstance(timeout, (int, float)):
            return self.reply(400)
        if not 0 <= timeout <= MAX_WAIT:
            return self.reply(400)
        self.reply_json(state.exec(text, timeout, kind))

    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        if self.refused(parts.path):
            return None
        query = urllib.parse.parse_qs(parts.query)
        state = self.server.state
        if parts.path == "/cli/status":
            return self.reply_json(state.status())
        if parts.path == "/cli/events":
            try:
                since = int(query.get("since", ["0"])[0])
                wait = min(float(query.get("wait", ["0"])[0]), MAX_WAIT)
            except ValueError:
                return self.reply(400)
            name = query.get("name", [None])[0]
            found, last = state.events_after(since, name, max(wait, 0.0))
            return self.reply_json({"events": found, "last": last, "run": state.run})
        self.reply(404)

    def reply_json(self, obj):
        self.reply(200, json.dumps(obj).encode(), "application/json")

    def reply(self, code, body=b"", content_type=None):
        self.send_response(code)
        if content_type:
            self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass  # the per-request access log is noise; we print our own line per batch


def make_server(port, out_dir):
    server = ThreadingHTTPServer((HOST, port), Handler)
    server.state = State(out_dir)
    return server


def run_daemon(args):
    sys.stdout.reconfigure(line_buffering=True)  # show output promptly even when piped
    args.out.mkdir(parents=True, exist_ok=True)
    server = make_server(args.port, args.out)
    print(f"listening on http://{HOST}:{args.port}, writing to {args.out}/")
    server.serve_forever()


# --- CLI side --------------------------------------------------------------------------------


class DaemonRefused(OSError):
    """A reachable daemon answered a request with a 4xx: the request itself was wrong."""


def call(args, path, payload=None, timeout=5.0):
    """One request to the daemon; the decoded JSON reply. Raises OSError if it isn't there."""
    url = f"http://{HOST}:{args.port}{path}"
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={"X-Rsdev": "1"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as err:  # a daemon that answers badly is still "up"
        if 400 <= err.code < 500:
            raise DaemonRefused(f"daemon rejected the request to {path} ({err.code})") from err
        raise OSError(f"daemon answered {err.code} to {path}") from err


def daemon_up(args):
    try:
        call(args, "/cli/status", timeout=1.0)
        return True
    except (OSError, ValueError):
        return False


def pid_file(args):
    return args.out / "rsdev" / "daemon.pid"


def cmd_start(args):
    if daemon_up(args):
        print(f"rsdev already running on port {args.port}")
        return 0
    folder = args.out / "rsdev"
    folder.mkdir(parents=True, exist_ok=True)
    log = (folder / "daemon.log").open("a")
    argv = [sys.executable, str(Path(__file__).resolve()), "daemon"]
    argv += ["--port", str(args.port), "--out", str(args.out)]
    # A new session, so closing the terminal that ran `start` doesn't take the daemon with it.
    proc = subprocess.Popen(
        argv, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
    )
    pid_file(args).write_text(f"{proc.pid}\n")
    for _ in range(50):
        if daemon_up(args):
            print(f"rsdev started (pid {proc.pid}), log {folder / 'daemon.log'}")
            return 0
        if proc.poll() is not None:
            break
        time.sleep(0.1)
    print(f"rsdev did not come up; see {folder / 'daemon.log'}", file=sys.stderr)
    return 1


def cmd_stop(args):
    path = pid_file(args)
    try:
        file_pid = int(path.read_text().strip())
    except (OSError, ValueError):
        file_pid = None
    try:
        daemon_pid = call(args, "/cli/status", timeout=1.0)["pid"]
    except (OSError, ValueError, KeyError):
        # Never signal a pid we couldn't confirm: with no answer, the file is only a leftover.
        if file_pid is None:
            print("rsdev is not running (no pid file)")
        else:
            path.unlink(missing_ok=True)
            print(f"rsdev is not running (stale pid file for {file_pid} removed)")
        return 0
    # The pid the daemon reports about itself is the proof. Without a pid file (a foreground
    # `daemon`), the reported pid is all there is to go on.
    # kill(0) signals our process group and kill(-1) every process we may signal, so only a real
    # int > 1 from the pid file or a reply reaches os.kill (`type` also rejects floats like 1.5).
    for label, pid, optional in (("daemon", daemon_pid, False), ("pid file", file_pid, True)):
        if not (optional and pid is None) and not (type(pid) is int and pid > 1):
            print(f"{label} pid {pid!r} is not a usable process id; not signalling", file=sys.stderr)
            return 1
    if file_pid is not None and file_pid != daemon_pid:
        print(
            f"pid file says {file_pid} but the daemon on port {args.port} reports {daemon_pid}; "
            "not signalling either",
            file=sys.stderr,
        )
        return 1
    try:
        os.kill(daemon_pid, signal.SIGTERM)
    except ProcessLookupError:  # it exited between the status call and the signal
        path.unlink(missing_ok=True)
        print(f"rsdev (pid {daemon_pid}) already gone")
        return 0
    for _ in range(50):
        if not daemon_up(args):
            break
        time.sleep(0.1)
    else:
        print(f"rsdev (pid {daemon_pid}) did not stop", file=sys.stderr)
        return 1
    path.unlink(missing_ok=True)
    print(f"rsdev stopped (pid {daemon_pid})")
    return 0


def cmd_status(args):
    try:
        st = call(args, "/cli/status")
    except (OSError, ValueError):
        print(f"daemon: not running on port {args.port}")
        return 0
    print(f"daemon: up on port {args.port}")
    bridge = st["bridge"]
    if bridge is None:
        print("bridge: never connected")
    else:
        if bridge["connected"]:
            print(f"bridge: connected (last sync {bridge['seen_ago']:.1f}s ago)")
        else:
            print(f"bridge: not connected (last sync {bridge['seen_ago']:.0f}s ago)")
        print(f"session: {bridge['session']}, seq {bridge['seq']}")
        hello = bridge["hello"] or {}
        print(f"version: {hello.get('version')}")
        env = hello.get("env") or {}
        print("env: " + (", ".join(f"{k}={v}" for k, v in sorted(env.items())) or "(none)"))
    print(f"commands: {st['queued']} queued, {st['awaiting_result']} awaiting a result")
    print(f"events: {st['events']}, dropped: {st['dropped']}")
    return 0


def daemon_lacks(args, kind):
    """Exit code 2 (printed why) if the daemon is unreachable or doesn't list `kind` in its
    status, else None. A daemon from before eval ignores `kind` and queues the source as an
    exec, so the bridge would run Lua as console input."""
    try:
        kinds = call(args, "/cli/status").get("kinds", [])
    except DaemonRefused as err:
        print(f"rsdev: {err}", file=sys.stderr)
        return 2
    except (OSError, ValueError, AttributeError) as err:
        print(f"rsdev daemon is not reachable on port {args.port}: {err}", file=sys.stderr)
        return 2
    # A status whose kinds isn't a list (null, or text that `in` would search) can't vouch.
    if isinstance(kinds, list) and kind in kinds:
        return None
    what = "eval --reset" if kind == "reset" else kind
    print(
        f"rsdev: the daemon on port {args.port} predates `rsdev.py {what}` (no {kind!r} in its "
        "status kinds); restart it: scripts/rsdev.py stop && scripts/rsdev.py start",
        file=sys.stderr,
    )
    return 2


def send_command(args, kind, text):
    """Queue a command and wait for its result. Returns (exit code, reply); the reply is the
    daemon's result dict when the code is 0, else None. Failures are already printed."""
    # exec is the one kind every daemon queues as itself, so only the others are checked.
    if kind != "exec":
        code = daemon_lacks(args, kind)
        if code is not None:
            return code, None
    # The daemon waits `timeout` itself; the extra seconds are for the reply to arrive.
    payload = {"kind": kind, "command": text, "timeout": args.timeout}
    try:
        reply = call(args, "/cli/exec", payload, args.timeout + 10)
    except DaemonRefused as err:
        print(f"rsdev: {err}", file=sys.stderr)
        return 2, None
    except (OSError, ValueError) as err:
        print(f"rsdev daemon is not reachable on port {args.port}: {err}", file=sys.stderr)
        return 2, None
    outcome = reply["outcome"]
    if outcome == "ok":
        return 0, reply
    if outcome == "error":
        # An eval's print output before the error is the best clue to where it failed.
        for line in reply.get("output", []) if kind == "eval" else []:
            print(line, file=sys.stderr)
        print(f"error: {reply['error']}", file=sys.stderr)
        return 1, None
    if outcome == "withdrawn":
        print(f"not delivered in {args.timeout}s (bridge not polling?); withdrawn", file=sys.stderr)
        return 2, None
    print(f"delivered but no result in {args.timeout}s: outcome unknown ({reply['id']})", file=sys.stderr)
    return 3, None


def exec_command(args):
    code, reply = send_command(args, "exec", " ".join(args.command))
    if reply:
        print(f"ok ({reply['id']})")
    return code


def cmd_eval(args):
    if args.reset:
        code, reply = send_command(args, "reset", "")
        if reply:
            print(f"ok ({reply['id']})")
        return code
    if args.file:
        try:
            source = args.file.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as err:
            print(f"rsdev: cannot read {args.file}: {err}", file=sys.stderr)
            return 2
    else:
        source = " ".join(args.code)
    code, reply = send_command(args, "eval", source)
    if reply:
        values = reply.get("values", [])
        shown = {
            "values": values,
            "nvalues": reply.get("nvalues", len(values)),
            "output": reply.get("output", []),
        }
        if reply.get("truncated"):
            shown["truncated"] = True
        print(json.dumps(shown, indent=2))
    return code


def cmd_exec(args):
    code = exec_command(args)
    # Shoot once the command has a result (ok or plugin error), not if it never reached the bridge.
    if not args.shot or code not in (0, 1):
        return code
    # Every shot option parsed for exec reaches the shot; only the series fields are fixed here.
    shot = SimpleNamespace(**{**vars(args), "count": 1, "every": 1, "delay": args.shot_delay})
    shot_code = cmd_shot(shot)
    if shot_code == 130:  # interrupted: stop quietly with the conventional status
        return 130
    return code or (4 if shot_code else 0)  # exec's own failure code stands


# ---- shot: capture the client window (host side; reads pixels, sends nothing to the client) ----


class ShotError(Exception):
    """A shot that cannot be taken; `code` is the exit status (1 capture failed, 2 can't try)."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def region_arg(text):
    """argparse type for --region: window-relative WxH+X+Y, as maim -g takes it."""
    m = re.fullmatch(r"([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)", text)
    if not m or int(m[1]) == 0 or int(m[2]) == 0:
        raise argparse.ArgumentTypeError(f"{text!r} is not WxH+X+Y with W and H above 0")
    return text


def window_arg(text):
    """argparse type for --window: an X window id such as 0x5a0002d."""
    if not re.fullmatch(r"0x[0-9a-fA-F]+", text, re.ASCII):
        raise argparse.ArgumentTypeError(f"{text!r} is not a window id like 0x5a0002d")
    return text


def number_arg(low, high, what, kind=float, low_open=False):
    """argparse type: a finite number from `low` to `high` (`low` itself excluded if low_open)."""

    def parse(text):
        try:
            value = kind(text)
        except ValueError:
            raise argparse.ArgumentTypeError(f"{text!r} is not a number") from None
        ok = math.isfinite(value) and (value > low if low_open else value >= low) and value <= high
        if not ok:
            raise argparse.ArgumentTypeError(f"{what} must be {'above' if low_open else 'from'} {low:g} to {high:g}")
        return value

    return parse


def parse_window_ids(text):
    """The ids in `xprop -root _NET_CLIENT_LIST` output."""
    return re.findall(r"0x[0-9a-fA-F]+", text.partition("#")[2])


def is_client_class(text):
    """True if `xprop WM_CLASS` output is exactly the game's class pair."""
    return re.findall(r'"([^"]*)"', text.partition("=")[2]) == CLIENT_WM_CLASS


def parse_cardinal(text):
    """The number in `xprop ... = 3` output, or None."""
    m = re.search(r"=\s*(-?\d+)\s*$", text.strip())
    return int(m[1]) if m else None


def parse_strings(text):
    """The quoted strings in `xprop _NET_DESKTOP_NAMES` output."""
    return re.findall(r'"((?:[^"\\]|\\.)*)"', text)


def is_viewable(wininfo):
    """True if `xwininfo` says the window is mapped and visible. An IsUnviewable window (on
    another workspace) would make maim silently capture whatever is on screen there."""
    return re.search(r"Map State:\s*IsViewable\b", wininfo) is not None


def window_number(win):
    return int(win, 16)


def convert_args(src, dest, max_px):
    """The ImageMagick argv for the downscaled JPEG; the trailing > shrinks and never enlarges."""
    return ["magick", str(src), "-resize", f"{max_px}x{max_px}>", "-quality", "85", str(dest)]


def shot_stamp(now):
    """The filename stamp for epoch time `now`; milliseconds keep shots started in one second apart."""
    return time.strftime("%Y%m%d-%H%M%S", time.localtime(now)) + f"-{int(now * 1000) % 1000:03d}"


def shot_paths(shots_dir, stamp, count, max_px):
    """The file for each shot of a series: <stamp>[-NN].<ext>, with NN only for a series."""
    ext = "png" if max_px == 0 else "jpg"
    if count == 1:
        return [shots_dir / f"{stamp}.{ext}"]
    width = max(2, len(str(count)))
    return [shots_dir / f"{stamp}-{i:0{width}d}.{ext}" for i in range(1, count + 1)]


def run_tool(argv):
    """Run an X or ImageMagick tool: the one place shot touches subprocess (tests replace it)."""
    return subprocess.run(argv, capture_output=True, text=True)


def tool_text(argv):
    """A tool's stdout, or ShotError(1) showing its stderr."""
    res = run_tool(argv)
    if res.returncode != 0:
        raise ShotError(1, f"{argv[0]} failed: {res.stderr.strip()}")
    return res.stdout


def find_client_window():
    """The client's window id, found through the window manager's client list by WM_CLASS."""
    listing = tool_text(["xprop", "-root", "_NET_CLIENT_LIST"])
    found = []
    for w in parse_window_ids(listing):
        res = run_tool(["xprop", "-id", w, "WM_CLASS"])
        # A window can close between the list and this query (BadWindow); it is not the client then.
        if res.returncode == 0 and is_client_class(res.stdout):
            found.append(w)
    if not found:
        raise ShotError(2, "client window not found (is the RS3 client running?)")
    if len(found) > 1:
        raise ShotError(2, f"several client windows found: {', '.join(found)}; pick one with --window")
    return found[0]


def workspace_hint(win):
    """Where a hidden window lives, for the refusal message."""
    index = parse_cardinal(tool_text(["xprop", "-id", win, "_NET_WM_DESKTOP"]))
    if index is None:
        return "its workspace is unknown"
    names = parse_strings(tool_text(["xprop", "-root", "_NET_DESKTOP_NAMES"]))
    name = f'"{names[index]}"' if 0 <= index < len(names) else f"number {index}"
    return f"it is on workspace {name}"


def check_visible(win, warn_focus=True):
    """Refuse a window that isn't viewable; optionally warn if something else has focus (and may
    cover it). Called before every capture: the window can leave the screen between shots."""
    res = run_tool(["xwininfo", "-id", win])
    if res.returncode != 0:  # a --window id that names nothing fails here
        lines = [ln.strip() for ln in res.stderr.splitlines() if ln.strip()]
        why = next((ln for ln in lines if "No such window" in ln), lines[0] if lines else "no output")
        raise ShotError(2, f"window {win} not found (xwininfo: {why.removeprefix('xwininfo: ')})")
    if not is_viewable(res.stdout):
        raise ShotError(2, f"window {win} is not visible: {workspace_hint(win)}. Switch to it yourself and retry.")
    if not warn_focus:
        return
    active = re.findall(r"0x[0-9a-fA-F]+", tool_text(["xprop", "-root", "_NET_ACTIVE_WINDOW"]))
    if active and window_number(active[0]) != window_number(win):
        print(
            "rsdev: the client is not the active window; other windows may cover it (floating ones are captured)",
            file=sys.stderr,
        )


def capture_one(win, dest, region, max_px):
    """Write one shot to `dest`: maim a PNG, then shrink it to a JPEG (unless max_px is 0).
    `dest` only ever appears complete, even on Ctrl-C: both tools write temp files next to it,
    which are renamed into place on success and always removed."""
    png = dest.with_name(dest.stem + ".tmp.png")
    jpg = dest.with_name(dest.stem + ".tmp.jpg")
    cmd = ["maim", "-u", "-i", win]  # -u hides the mouse cursor
    if region:
        cmd += ["-g", region]
    try:
        res = run_tool(cmd + [str(png)])
        if res.returncode != 0:
            raise ShotError(1, f"maim failed: {res.stderr.strip()}")
        if max_px:
            res = run_tool(convert_args(png, jpg, max_px))
            if res.returncode != 0:
                raise ShotError(1, f"magick failed: {res.stderr.strip()}")
            jpg.replace(dest)
        else:
            png.replace(dest)
    finally:
        png.unlink(missing_ok=True)
        jpg.unlink(missing_ok=True)


def take_shots(opts):
    """Take the shots `opts` asks for, printing each path as it is written; raises ShotError."""
    needed = SHOT_TOOLS + (("magick",) if opts.max else ())
    for tool in needed:
        if shutil.which(tool) is None:
            raise ShotError(2, f"{tool} not found: enter the dev shell (direnv)")
    win = opts.window or find_client_window()
    shots_dir = opts.out / "rsdev" / "shots"
    shots_dir.mkdir(parents=True, exist_ok=True)
    paths = shot_paths(shots_dir, shot_stamp(time.time()), opts.count, opts.max)
    if opts.delay:
        time.sleep(opts.delay)
    started = None
    for path in paths:
        if started is not None:  # `every` runs start to start; an overrun makes the next one immediate
            wait = started + opts.every - time.monotonic()
            if wait > 0:
                time.sleep(wait)
        started = time.monotonic()
        check_visible(win, warn_focus=path == paths[0])
        capture_one(win, path, opts.region, opts.max)
        print(path, flush=True)


def cmd_shot(args):
    try:
        take_shots(args)
    except ShotError as err:
        print(f"rsdev: {err}", file=sys.stderr)
        return err.code
    except KeyboardInterrupt:  # shots already printed stay valid
        return 130
    return 0


def follow_events(args, name, show):
    """Print events through `show`: those after args.since, named `name` (None for all), and with
    args.follow, new ones as they arrive. Returns the exit code."""
    since = args.since
    run = None  # the daemon run the numbers belong to
    delay = None  # backoff before the next retry; None while connected
    while True:
        # After a drop, ask without waiting: a long poll with the old `since` would sit on a new
        # daemon's low-numbered events until it timed out, before the run change showed.
        wait = 25 if args.follow and delay is None else 0
        path = f"/cli/events?since={since}&wait={wait}"
        if name:
            path += "&name=" + urllib.parse.quote(name)
        try:
            reply = call(args, path, timeout=wait + 10)
        except KeyboardInterrupt:
            return 0
        except (OSError, ValueError) as err:
            if not args.follow:
                print(f"rsdev daemon is not reachable on port {args.port}: {err}", file=sys.stderr)
                return 2
            # A restart always drops the long-poll connection, so --follow waits it out.
            if delay is None:
                print("daemon not reachable; retrying", file=sys.stderr)
                delay = 0.5
            try:
                time.sleep(delay)
            except KeyboardInterrupt:
                return 0
            delay = min(delay * 2, 5.0)
            continue
        if delay is not None:
            print("daemon reachable again", file=sys.stderr)
            delay = None
        if run is not None and reply["run"] != run:
            # A new daemon numbers from 1 again, and this reply used the old `since`: drop it and
            # refetch from the start.
            print("daemon restarted; numbering restarted", file=sys.stderr)
            run, since = reply["run"], 0
            continue
        for event in reply["events"]:
            show(event)
        run, since = reply["run"], reply["last"]
        if not args.follow:
            return 0


def cmd_events(args):
    return follow_events(args, args.name, lambda event: print(json.dumps(event), flush=True))


def format_log(event):
    """`n [plugin] level: text`; the text's later lines are indented under the first."""
    payload = event.get("payload")
    payload = payload if isinstance(payload, dict) else {}
    text = str(payload.get("text", "")).replace("\n", "\n    ")
    return f"{event['n']} [{payload.get('plugin')}] {payload.get('level')}: {text}"


def cmd_logs(args):
    def show(event):
        payload = event.get("payload")
        if args.plugin and not (isinstance(payload, dict) and payload.get("plugin") == args.plugin):
            return
        print(json.dumps(event) if args.json else format_log(event), flush=True)

    return follow_events(args, "Log", show)


def main(argv=None):
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--port", type=int, default=DEFAULT_PORT)
    common.add_argument("--out", type=Path, default=DEFAULT_OUT)
    shot_opts = argparse.ArgumentParser(add_help=False)
    shot_opts.add_argument("--window", type=window_arg, help="X window id; skips the lookup by WM_CLASS")
    shot_opts.add_argument("--region", type=region_arg, help="WxH+X+Y inside the window")
    shot_opts.add_argument(
        "--max",
        type=number_arg(0, 100_000, "--max", int),
        default=DEFAULT_SHOT_MAX,
        help="shrink to fit this many pixels and write a JPEG; 0 keeps the full-size PNG",
    )
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("daemon", parents=[common]).set_defaults(run=run_daemon)
    for name, fn in (("start", cmd_start), ("stop", cmd_stop), ("status", cmd_status)):
        sub.add_parser(name, parents=[common]).set_defaults(run=fn)
    p = sub.add_parser("exec", parents=[common, shot_opts])
    p.set_defaults(max=None)  # unset, so a shot option given without --shot is detectable
    p.add_argument("command", nargs="+")
    p.add_argument("--timeout", type=number_arg(0, MAX_WAIT, "--timeout", low_open=True), default=10.0)
    p.add_argument("--shot", action="store_true", help="capture the client once the command has a result")
    p.add_argument("--shot-delay", type=number_arg(0, 60, "--shot-delay"))
    p.set_defaults(run=cmd_exec)
    p = sub.add_parser("events", parents=[common])
    p.add_argument("--since", type=int, default=0)
    p.add_argument("--follow", action="store_true")
    p.add_argument("--name")
    p.set_defaults(run=cmd_events)
    p = sub.add_parser("eval", parents=[common], help="run Lua in the client and print the result")
    p.add_argument("code", nargs="*")
    p.add_argument("--file", type=Path, help="read the Lua source from this file instead")
    p.add_argument("--reset", action="store_true", help="clear the plugin's eval state")
    p.add_argument("--timeout", type=number_arg(0, MAX_WAIT, "--timeout", low_open=True), default=10.0)
    p.set_defaults(run=cmd_eval)
    p = sub.add_parser("logs", parents=[common], help="print the Log events plugins forward")
    p.add_argument("--since", type=int, default=0)
    p.add_argument("--follow", action="store_true")
    p.add_argument("--plugin")
    p.add_argument("--json", action="store_true", help="print the raw event JSON lines")
    p.set_defaults(run=cmd_logs)
    p = sub.add_parser("shot", parents=[common, shot_opts], help="capture the client window to an image")
    p.add_argument("--count", type=number_arg(1, MAX_SHOT_COUNT, "--count", int), default=1)
    p.add_argument("--every", type=number_arg(0, 3600, "--every", low_open=True), default=1.0)
    p.add_argument("--delay", type=number_arg(0, 3600, "--delay"), default=0.0)
    p.set_defaults(run=cmd_shot)
    args = parser.parse_args(argv)
    if args.cmd == "exec":
        given = [f for f in ("window", "region", "max", "shot_delay") if getattr(args, f) is not None]
        if given and not args.shot:
            parser.error("--window, --region, --max and --shot-delay only apply with --shot")
        args.max = DEFAULT_SHOT_MAX if args.max is None else args.max
        args.shot_delay = 1.0 if args.shot_delay is None else args.shot_delay
    if args.cmd == "eval":
        sources = bool(args.code) + (args.file is not None)
        if args.reset and sources:
            parser.error("--reset takes no code and no --file")
        if not args.reset and sources != 1:
            parser.error("give the Lua code as words or with --file, not both and not neither")
    return args.run(args) or 0


if __name__ == "__main__":
    sys.exit(main())
