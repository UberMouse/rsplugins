"""Tests for scripts/rsdev.py, run by scripts/check-lua.sh:

    python3 -m unittest scripts/test_rsdev.py

Each test runs a real daemon server on an ephemeral port, writing to a temp dir, and talks to it
over HTTP the way the recorder, the bridge plugin and the CLI do."""

import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from unittest import mock
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from types import SimpleNamespace

SCRIPT = Path(__file__).with_name("rsdev.py")
spec = importlib.util.spec_from_file_location("rsdev", SCRIPT)
rsdev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rsdev)


def post(port, path, body, headers=None, cli=True):
    """POST; returns (status, body text). `body` may be bytes or a JSON-able value.

    Sends X-Rsdev like the CLI does, unless cli=False."""
    data = body if isinstance(body, bytes) else json.dumps(body).encode()
    sent = {"X-Rsdev": "1"} if cli else {}
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data, headers={**sent, **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as err:
        return err.code, err.read().decode()


def get(port, path):
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"X-Rsdev": "1"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.load(resp)


def batch(**over):
    return {
        "schema": 1,
        "plugin": "demo",
        "session": "s1",
        "seq": 1,
        "dropped": 0,
        "entries": [{"k": "event", "t": 5, "name": "X"}],
        **over,
    }


def sync_body(**over):
    return {
        "schema": 1,
        "plugin": "dev-bridge",
        "session": "b1",
        "seq": 1,
        "dropped": 0,
        "hello": {"version": "Lua 5.4", "env": {"load": "function", "io": "nil"}},
        "events": [],
        "results": [],
        **over,
    }


def parse_lines(text):
    """The sync response as (id, kind, unescaped arg) tuples."""
    assert text == "" or text.endswith("\n")
    return [
        (i, k, rsdev.unescape_arg(a)) for i, k, a in (ln.split("\t") for ln in text.splitlines())
    ]


class DaemonCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.server = rsdev.make_server(0, self.out)
        self.port = self.server.server_address[1]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        self.thread.start()
        self.log = StringIO()
        # The daemon prints a line per request; capture it. Handler threads share sys.stdout.
        self.redirect = redirect_stdout(self.log)
        self.redirect.__enter__()

    def tearDown(self):
        self.redirect.__exit__(None, None, None)
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def sync(self, **over):
        status, text = post(self.port, "/bridge/sync", sync_body(**over))
        self.assertEqual(status, 200)
        return parse_lines(text)

    def exec_async(self, command, timeout=5):
        """Run `exec` on another thread; returns (thread, result dict filled in when done)."""
        result = {}

        def run():
            result.update(json.loads(post(self.port, "/cli/exec", {"command": command, "timeout": timeout})[1]))

        t = threading.Thread(target=run)
        t.start()
        return t, result

    def wait_queued(self, n=1):
        for _ in range(500):
            if self.server.state.status()["queued"] >= n:
                return
            threading.Event().wait(0.01)
        self.fail("command never queued")


class RecordTests(DaemonCase):
    def files(self):
        return sorted((self.out / "recordings" / "demo").glob("*.jsonl"))

    def lines(self, path):
        return [json.loads(ln) for ln in path.read_text().splitlines()]

    def test_good_batch_writes_header_and_entries(self):
        self.assertEqual(post(self.port, "/record", batch())[0], 200)
        (path,) = self.files()
        header, entry = self.lines(path)
        self.assertEqual((header["k"], header["plugin"], header["session"]), ("session", "demo", "s1"))
        self.assertEqual(list(entry), ["t", "k", "name"])  # t and k first

    def test_second_batch_appends_to_the_same_file(self):
        post(self.port, "/record", batch())
        post(self.port, "/record", batch(seq=2))
        (path,) = self.files()
        self.assertEqual(len(self.lines(path)), 3)

    def test_dropped_growth_writes_a_marker_once(self):
        post(self.port, "/record", batch(dropped=4))
        post(self.port, "/record", batch(seq=2, dropped=4))
        (path,) = self.files()
        marks = [ln for ln in self.lines(path) if ln["k"] == "dropped"]
        self.assertEqual(marks, [{"t": 5, "k": "dropped", "n": 4}])

    def test_seq_going_back_down_starts_a_new_file(self):
        post(self.port, "/record", batch(seq=3))
        post(self.port, "/record", batch(seq=1))
        self.assertEqual(len(self.files()), 2)

    def test_bad_bodies_are_400_and_write_nothing(self):
        for bad in (
            b"not json",
            [],
            batch(plugin="../x"),
            batch(session=""),
            batch(seq=0),
            batch(seq=True),
            batch(schema="1"),
            batch(dropped=-1),
            batch(dropped="2"),
            batch(entries="x"),
            batch(entries=[1]),
        ):
            self.assertEqual(post(self.port, "/record", bad)[0], 400, bad)
        self.assertFalse((self.out / "recordings").exists())

    def test_unknown_path_is_404(self):
        self.assertEqual(post(self.port, "/nope", {})[0], 404)

    def test_content_length_rules(self):
        for length in ("", "-1", "abc", "1" * 11):
            self.assertEqual(self.raw_post("/record", length), 400, length)
        self.assertEqual(self.raw_post("/record", str(rsdev.MAX_BODY + 1)), 413)

    def raw_post(self, path, length):
        """POST with a hand-written Content-Length and no body."""
        import socket

        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            head = f"POST {path} HTTP/1.0\r\nHost: 127.0.0.1:{self.port}\r\n" + (f"Content-Length: {length}\r\n" if length else "")
            s.sendall((head + "\r\n").encode())
            return int(s.recv(100).split()[1])


class SyncTests(DaemonCase):
    def test_validation_rejects_without_applying(self):
        for bad in (
            [],
            sync_body(plugin="a/b"),
            sync_body(session=5),
            sync_body(seq=0),
            sync_body(dropped=-1),
            sync_body(hello="x"),
            sync_body(hello={"env": {"io": 3}}),
            sync_body(events="x"),
            sync_body(events=[{"t": 1}]),
            sync_body(events=[{"name": "A", "t": "late"}]),
            sync_body(results=[{"id": "a", "ok": "yes"}]),
            sync_body(results=[{"id": 1, "ok": True}]),
            sync_body(results=[{"id": "a", "ok": False, "error": 3}]),
        ):
            self.assertEqual(post(self.port, "/bridge/sync", bad)[0], 400, bad)
        st = self.server.state.status()
        self.assertEqual((st["bridge"], st["events"]), (None, 0))

    def test_sync_records_hello_and_seen_time(self):
        self.sync(seq=7)
        bridge = self.server.state.status()["bridge"]
        self.assertEqual(bridge["seq"], 7)
        self.assertEqual(bridge["hello"]["env"]["load"], "function")
        self.assertTrue(bridge["connected"])

    def test_a_sync_without_hello_keeps_the_last_one(self):
        self.sync()
        body = sync_body(seq=2)
        del body["hello"]
        post(self.port, "/bridge/sync", body)
        self.assertEqual(self.server.state.status()["bridge"]["hello"]["version"], "Lua 5.4")

    def test_response_is_text_plain(self):
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/bridge/sync", data=json.dumps(sync_body()).encode()
        )
        with urllib.request.urlopen(req) as resp:
            self.assertTrue(resp.headers["Content-Type"].startswith("text/plain"))

    def test_command_lines_round_trip_special_characters(self):
        nasty = "say a\tb\nc\rd \\ e \\n"
        t, result = self.exec_async(nasty)
        self.wait_queued()
        (line,) = self.sync()
        self.assertEqual(line[1:], ("exec", nasty))
        self.sync(seq=2, results=[{"id": line[0], "ok": True}])
        t.join()
        self.assertEqual(result["outcome"], "ok")

    def test_each_command_is_delivered_once_in_order(self):
        t1, _ = self.exec_async("one")
        self.wait_queued(1)
        t2, _ = self.exec_async("two")
        self.wait_queued(2)
        self.assertEqual([c[2] for c in self.sync()], ["one", "two"])
        self.assertEqual(self.sync(seq=2), [])
        for line_id in list(self.server.state.commands):
            self.server.state.sync(sync_body(seq=3, results=[{"id": line_id, "ok": True}]))
        t1.join()
        t2.join()

    def test_events_get_increasing_n_and_are_persisted(self):
        events = [{"t": 1, "name": "A", "payload": {"x": 1}}, {"t": 2, "name": "B", "payload": None}]
        self.sync(events=events)
        self.sync(seq=2, events=[{"t": 3, "name": "A", "payload": 1}])
        got = get(self.port, "/cli/events")["events"]
        self.assertEqual([e["n"] for e in got], [1, 2, 3])
        on_disk = (self.out / "rsdev" / "events" / "b1.jsonl").read_text().splitlines()
        self.assertEqual([json.loads(ln)["n"] for ln in on_disk], [1, 2, 3])

    def test_an_events_own_n_and_session_keys_do_not_override_the_daemons(self):
        self.sync(events=[{"t": 1, "name": "A", "n": 99, "session": "evil"}, {"t": 2, "name": "B"}])
        got = get(self.port, "/cli/events")["events"]
        self.assertEqual([(e["n"], e["session"]) for e in got], [(1, "b1"), (2, "b1")])
        self.assertEqual([e["name"] for e in get(self.port, "/cli/events?since=1")["events"]], ["B"])

    def test_dropped_growth_becomes_a_marker_event(self):
        self.sync(dropped=3, events=[{"t": 9, "name": "A", "payload": 1}])
        self.sync(seq=2, dropped=3)
        self.sync(seq=3, dropped=5)
        marks = [e for e in get(self.port, "/cli/events")["events"] if e["name"] == "dropped"]
        self.assertEqual([m["n_lost"] for m in marks], [3, 2])
        self.assertEqual(self.server.state.status()["dropped"], 5)

    def test_memory_keeps_only_the_last_events(self):
        many = [{"t": i, "name": "A", "payload": i} for i in range(rsdev.MAX_EVENTS + 5)]
        self.server.state.sync(sync_body(events=many))
        got = get(self.port, "/cli/events")["events"]
        self.assertEqual((len(got), got[0]["n"]), (rsdev.MAX_EVENTS, 6))

    def test_new_session_fails_commands_the_old_one_never_reported(self):
        self.sync()
        t, result = self.exec_async("hang")
        self.wait_queued()
        self.sync(seq=2)  # delivered
        self.sync(session="b2")  # plugin reloaded without reporting
        t.join()
        self.assertEqual(result["outcome"], "error")
        self.assertIn("bridge restarted before reporting", result["error"])
        self.assertIn("new session b2", self.log.getvalue())


class ExecTests(DaemonCase):
    def test_ok_and_error_results(self):
        for ok, error in ((True, ""), (False, "boom")):
            t, result = self.exec_async("cmd")
            self.wait_queued()
            (line,) = self.sync()
            self.sync(seq=2, results=[{"id": line[0], "ok": ok, "error": error}])
            t.join()
            self.assertEqual(result["outcome"], "ok" if ok else "error")
            self.assertEqual(result["error"], error)

    def test_undelivered_command_is_withdrawn_and_never_delivered_later(self):
        status, text = post(self.port, "/cli/exec", {"command": "late", "timeout": 0.2})
        self.assertEqual(json.loads(text)["outcome"], "withdrawn")
        self.assertEqual(self.sync(), [])

    def test_delivered_without_result_is_unknown(self):
        t, result = self.exec_async("slow", timeout=0.5)
        self.wait_queued()
        self.assertEqual(len(self.sync()), 1)
        t.join()
        self.assertEqual(result["outcome"], "unknown")

    def test_unknown_outcome_forgets_the_command_and_ignores_a_late_result(self):
        t, result = self.exec_async("slow", timeout=0.3)
        self.wait_queued()
        (line,) = self.sync()
        t.join()
        self.assertEqual(result["outcome"], "unknown")
        self.assertEqual(self.server.state.status()["awaiting_result"], 0)
        self.sync(seq=2, results=[{"id": line[0], "ok": True}])
        self.assertIn(f"ignored result for unknown command id '{line[0]}'", self.log.getvalue())

    def test_every_queued_command_is_logged_with_its_id(self):
        t, result = self.exec_async("give item")
        self.wait_queued()
        (line,) = self.sync()
        self.sync(seq=2, results=[{"id": line[0], "ok": True}])
        t.join()
        self.assertIn(f"queued command {line[0]}: exec 'give item'", self.log.getvalue())

    def test_bad_exec_request_is_400(self):
        for bad in ({}, {"command": "", "timeout": 1}, {"command": "x"}, {"command": "x", "timeout": -1}):
            self.assertEqual(post(self.port, "/cli/exec", bad)[0], 400, bad)

    def test_cli_exec_exit_codes(self):
        args = SimpleNamespace(port=self.port, command=["x", "y"], timeout=0.2, shot=False)
        err = StringIO()
        with redirect_stdout(StringIO()), mock.patch("sys.stderr", err):
            self.assertEqual(rsdev.cmd_exec(args), 2)  # nobody polling: withdrawn
            args.port = 1  # nothing listens there
            self.assertEqual(rsdev.cmd_exec(args), 2)

    def test_a_request_the_daemon_rejects_is_not_reported_as_unreachable(self):
        args = SimpleNamespace(port=self.port, command=["x"], timeout=-1, shot=False)
        err = StringIO()
        with mock.patch("sys.stderr", err):
            self.assertEqual(rsdev.cmd_exec(args), 2)
        self.assertIn("rejected", err.getvalue())
        self.assertNotIn("not reachable", err.getvalue())

    def test_timeout_option_range(self):
        for bad in ("-1", "0", "121", "nan", "abc"):
            with self.subTest(bad), mock.patch("sys.stderr", StringIO()):
                with self.assertRaises(SystemExit):
                    rsdev.main(["exec", "--timeout", bad, "x"])
        parse = rsdev.number_arg(0, rsdev.MAX_WAIT, "--timeout", low_open=True)
        self.assertEqual(parse("120"), 120.0)
        self.assertEqual(parse("0.5"), 0.5)


class BrowserGuardTests(DaemonCase):
    """A web page must not be able to drive the daemon (CSRF, DNS rebinding)."""

    def bodies(self):
        return {
            "/cli/exec": {"command": "cheat", "timeout": 0.1},
            "/bridge/sync": sync_body(),
            "/record": batch(),
        }

    def assert_untouched(self):
        st = self.server.state.status()
        self.assertEqual((st["bridge"], st["queued"], st["events"]), (None, 0, 0))
        self.assertFalse((self.out / "recordings").exists())
        self.assertNotIn("queued command", self.log.getvalue())

    def test_origin_is_refused_on_every_post_route(self):
        for route, body in self.bodies().items():
            hdr = {"Origin": "http://evil.example"}
            self.assertEqual(post(self.port, route, body, hdr)[0], 403, route)
            self.assertIn(f"refused {route}: Origin", self.log.getvalue())
        self.assert_untouched()

    def test_origin_is_refused_on_get_routes(self):
        for route in ("/cli/status", "/cli/events"):
            req = urllib.request.Request(
                f"http://127.0.0.1:{self.port}{route}", headers={"X-Rsdev": "1", "Origin": "null"}
            )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                urllib.request.urlopen(req)
            self.assertEqual(caught.exception.code, 403)

    def test_foreign_host_is_refused(self):
        for host in ("evil.example", f"evil.example:{self.port}", "127.0.0.1", f"127.0.0.1:{self.port + 1}"):
            for route, body in self.bodies().items():
                self.assertEqual(post(self.port, route, body, {"Host": host})[0], 403, (host, route))
        self.assert_untouched()
        self.assertIn("refused /record: Host 'evil.example'", self.log.getvalue())

    def test_localhost_host_is_accepted(self):
        status, _ = post(self.port, "/record", batch(), {"Host": f"localhost:{self.port}"})
        self.assertEqual(status, 200)

    def test_cli_routes_need_x_rsdev(self):
        body = self.bodies()["/cli/exec"]
        self.assertEqual(post(self.port, "/cli/exec", body, cli=False)[0], 403)
        self.assertEqual(post(self.port, "/cli/exec", body, {"X-Rsdev": "0"}, cli=False)[0], 403)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}/cli/status")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code, 403)
        self.assert_untouched()
        # the plugin-facing routes don't need it
        self.assertEqual(post(self.port, "/record", batch(), cli=False)[0], 200)

    def test_the_clis_own_requests_work(self):
        args = SimpleNamespace(port=self.port)
        self.assertTrue(rsdev.call(args, "/cli/status")["up"])
        self.assertEqual(rsdev.call(args, "/cli/events")["events"], [])
        reply = rsdev.call(args, "/cli/exec", {"command": "x", "timeout": 0.1})
        self.assertEqual(reply["outcome"], "withdrawn")


class StopTests(DaemonCase):
    def args(self):
        return SimpleNamespace(port=self.port, out=self.out)

    def write_pid(self, pid):
        path = rsdev.pid_file(self.args())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"{pid}\n")
        return path

    def fake_kill(self):
        """os.kill that records the call and, for SIGTERM, stops the in-process server."""
        calls = []

        def kill(pid, sig):
            calls.append((pid, sig))
            threading.Thread(target=self.server.shutdown).start()
            self.server.socket.close()  # nothing answers from here on

        return calls, kill

    def test_stops_a_live_daemon_whose_pid_matches_the_file(self):
        path = self.write_pid(os.getpid())  # the in-process server reports our own pid
        calls, kill = self.fake_kill()
        with mock.patch.object(rsdev.os, "kill", kill), redirect_stdout(StringIO()):
            self.assertEqual(rsdev.cmd_stop(self.args()), 0)
        self.assertEqual(calls, [(os.getpid(), rsdev.signal.SIGTERM)])
        self.assertFalse(path.exists())

    def test_stops_a_daemon_with_no_pid_file_by_its_reported_pid(self):
        calls, kill = self.fake_kill()
        with mock.patch.object(rsdev.os, "kill", kill), redirect_stdout(StringIO()):
            self.assertEqual(rsdev.cmd_stop(self.args()), 0)
        self.assertEqual([c[0] for c in calls], [os.getpid()])

    def test_stale_pid_file_is_removed_and_nothing_is_signalled(self):
        self.server.shutdown()
        self.server.socket.close()  # the daemon is gone
        path = self.write_pid(12345)
        with mock.patch.object(rsdev.os, "kill") as kill, redirect_stdout(StringIO()) as out:
            self.assertEqual(rsdev.cmd_stop(self.args()), 0)
        kill.assert_not_called()
        self.assertFalse(path.exists())
        self.assertIn("stale", out.getvalue())

    def test_pid_file_naming_another_pid_is_not_signalled(self):
        path = self.write_pid(os.getpid() + 1)
        with mock.patch.object(rsdev.os, "kill") as kill, mock.patch("sys.stderr", StringIO()):
            self.assertEqual(rsdev.cmd_stop(self.args()), 1)
        kill.assert_not_called()
        self.assertTrue(path.exists())

    def test_unusable_pids_are_never_signalled(self):
        for bad in (0, -1, 1, "x", True, 1.5, None):
            with self.subTest(status_pid=bad):
                with mock.patch.object(rsdev.os, "kill") as kill, mock.patch.object(
                    rsdev, "call", lambda *a, **k: {"pid": bad}
                ), mock.patch("sys.stderr", StringIO()):
                    self.assertEqual(rsdev.cmd_stop(self.args()), 1)
                kill.assert_not_called()
        for bad in (0, -1, 1):
            with self.subTest(file_pid=bad):
                self.write_pid(bad)
                with mock.patch.object(rsdev.os, "kill") as kill, mock.patch.object(
                    rsdev, "call", lambda *a, **k: {"pid": os.getpid()}
                ), mock.patch("sys.stderr", StringIO()):
                    self.assertEqual(rsdev.cmd_stop(self.args()), 1)
                kill.assert_not_called()

    def test_daemon_that_exited_before_the_signal_is_already_gone(self):
        path = self.write_pid(os.getpid())
        with mock.patch.object(rsdev.os, "kill", side_effect=ProcessLookupError), redirect_stdout(
            StringIO()
        ) as out:
            self.assertEqual(rsdev.cmd_stop(self.args()), 0)
        self.assertFalse(path.exists())
        self.assertIn("already gone", out.getvalue())


def tee_body(**over):
    return {
        "schema": 1,
        "plugin": "demo",
        "session": "t1",
        "seq": 1,
        "dropped": 0,
        "lines": [{"t": 7, "level": "print", "text": "hello"}],
        **over,
    }


class ResultFieldTests(DaemonCase):
    def test_bad_field_types_are_400_and_apply_nothing(self):
        for bad in (
            {"values": "x"},
            {"values": {"a": 1}},
            {"nvalues": "2"},
            {"nvalues": 1.5},
            {"nvalues": True},
            {"output": "x"},
            {"output": ["a", 3]},
            {"truncated": 1},
            {"truncated": "true"},
        ):
            body = sync_body(results=[{"id": "a", "ok": True, **bad}])
            self.assertEqual(post(self.port, "/bridge/sync", body)[0], 400, bad)
        self.assertIsNone(self.server.state.status()["bridge"])

    def test_good_fields_are_kept_for_the_waiting_request(self):
        t, result = self.exec_async("1+1")
        self.wait_queued()
        (line,) = self.sync()
        fields = {"values": [2, None, {"a": [1]}], "nvalues": 4, "output": ["x"], "truncated": True}
        self.sync(seq=2, results=[{"id": line[0], "ok": True, **fields}])
        t.join()
        self.assertEqual({k: result[k] for k in fields}, fields)


class ThreadOutput:
    """A stdout that sends a thread's writes to its own buffer if it set one (the CLI under test),
    else to `default` (the daemon's handler threads). redirect_stdout alone is process-wide."""

    def __init__(self, default):
        self.default, self.local = default, threading.local()

    def write(self, text):
        return getattr(self.local, "buf", self.default).write(text)

    def flush(self):
        pass


class CliCase(DaemonCase):
    def setUp(self):
        super().setUp()
        self.stdout = ThreadOutput(self.log)
        sys.stdout = self.stdout  # tearDown's redirect exit restores the real one

    def run_cli(self, *argv):
        """Run the CLI on another thread; returns (thread, dict of code/stdout/stderr)."""
        out = {}

        def run():
            stdout, stderr = StringIO(), StringIO()
            self.stdout.local.buf = stdout
            with mock.patch("sys.stderr", stderr):
                out["code"] = rsdev.main([*argv, "--port", str(self.port)])
            out["stdout"], out["stderr"] = stdout.getvalue(), stderr.getvalue()

        t = threading.Thread(target=run)
        t.start()
        return t, out

    def deliver(self, **result):
        """Sync until the queued command arrives, then report `result` for it. Returns its line."""
        self.wait_queued()
        (line,) = self.sync()
        self.sync(seq=2, results=[{"id": line[0], **result}])
        return line


class EvalTests(CliCase):
    def test_round_trip_prints_the_result_as_json(self):
        t, out = self.run_cli("eval", "return", "1,\tnil\nx\\")
        line = self.deliver(ok=True, values=[1], nvalues=2, output=["hi"])
        t.join()
        self.assertEqual(line[1:], ("eval", "return 1,\tnil\nx\\"))
        self.assertEqual(out["code"], 0)
        self.assertEqual(json.loads(out["stdout"]), {"values": [1], "nvalues": 2, "output": ["hi"]})
        self.assertIn('\n  "values"', out["stdout"])  # indent 2

    def test_truncated_is_shown_only_when_set(self):
        t, out = self.run_cli("eval", "x")
        self.deliver(ok=True, values=[], nvalues=0, output=[], truncated=True)
        t.join()
        self.assertIs(json.loads(out["stdout"])["truncated"], True)

    def test_a_lua_error_exits_1_on_stderr(self):
        t, out = self.run_cli("eval", "error('x')")
        self.deliver(ok=False, error="boom")
        t.join()
        self.assertEqual((out["code"], out["stdout"]), (1, ""))
        self.assertIn("boom", out["stderr"])

    def test_a_lua_error_shows_the_output_printed_before_it(self):
        t, out = self.run_cli("eval", "print('a') error('x')")
        self.deliver(ok=False, error="boom", output=["a", "b"])
        t.join()
        self.assertEqual((out["code"], out["stdout"]), (1, ""))
        self.assertEqual(out["stderr"].splitlines(), ["a", "b", "error: boom"])

    def test_multi_line_source_arrives_escaped_on_one_line(self):
        t, out = self.run_cli("eval", "local a = 1\nreturn a")
        line = self.deliver(ok=True, values=[1], nvalues=1, output=[])
        t.join()
        self.assertEqual(line[2], "local a = 1\nreturn a")

    def test_file_is_read_whole(self):
        src = self.out / "snippet.lua"
        src.write_text("local a = 1\nreturn a\n")
        t, out = self.run_cli("eval", "--file", str(src))
        line = self.deliver(ok=True, values=[1], nvalues=1, output=[])
        t.join()
        self.assertEqual(line[1:], ("eval", "local a = 1\nreturn a\n"))

    def test_unreadable_file_exits_2(self):
        t, out = self.run_cli("eval", "--file", str(self.out / "missing.lua"))
        t.join()
        self.assertEqual(out["code"], 2)
        self.assertIn("cannot read", out["stderr"])

    def test_usage_errors(self):
        for argv in (
            ["eval"],
            ["eval", "--file", "f", "x"],
            ["eval", "--reset", "x"],
            ["eval", "--reset", "--file", "f"],
        ):
            with self.subTest(argv), mock.patch("sys.stderr", StringIO()):
                with self.assertRaises(SystemExit) as ctx:
                    rsdev.main(argv)
                self.assertEqual(ctx.exception.code, 2)

    def test_reset_queues_a_reset_with_an_empty_arg(self):
        t, out = self.run_cli("eval", "--reset")
        line = self.deliver(ok=True)
        t.join()
        self.assertEqual(line[1:], ("reset", ""))
        self.assertEqual(out["code"], 0)

    def test_exit_codes_for_undelivered_and_unanswered(self):
        t, out = self.run_cli("eval", "--timeout", "0.2", "x")
        t.join()
        self.assertEqual(out["code"], 2)  # nobody polling: withdrawn
        self.assertEqual(self.sync(), [])
        t, out = self.run_cli("eval", "--timeout", "0.3", "x")
        self.wait_queued()
        self.assertEqual(len(self.sync(seq=2)), 1)
        t.join()
        self.assertEqual(out["code"], 3)

    def test_cli_requests_reject_a_bad_kind_or_arg(self):
        for bad in (
            {"kind": "nope", "command": "x"},
            {"kind": "eval", "command": ""},
            {"kind": "reset", "command": "x"},
            {"kind": 5, "command": "x"},
        ):
            self.assertEqual(post(self.port, "/cli/exec", {**bad, "timeout": 1})[0], 400, bad)

    def test_the_audit_log_names_each_eval_and_reset_and_cuts_long_sources(self):
        source = "x" * 250
        for kind, text in (("eval", source), ("reset", "")):
            t, result = self.exec_kind(kind, text)
            line = self.deliver(ok=True)
            t.join()
            self.assertIn(f"queued command {line[0]}: {kind}", self.log.getvalue())
        log = self.log.getvalue()
        self.assertIn("x" * 200 + "' (+50 more characters)", log)
        self.assertNotIn("x" * 201, log)

    def exec_kind(self, kind, text):
        result = {}

        def run():
            body = {"kind": kind, "command": text, "timeout": 5}
            result.update(json.loads(post(self.port, "/cli/exec", body)[1]))

        t = threading.Thread(target=run)
        t.start()
        return t, result


class StaleDaemonTests(DaemonCase):
    def test_status_lists_the_command_kinds(self):
        args = SimpleNamespace(port=self.port)
        self.assertEqual(rsdev.call(args, "/cli/status")["kinds"], ["exec", "eval", "reset"])

    def cli_against(self, status, *argv):
        """Run the CLI against a fake daemon whose status is `status`; (code, stderr, paths)."""
        paths = []

        def fake_call(args, path, payload=None, timeout=5.0):
            paths.append(path)
            if path == "/cli/status":
                return status
            return {"outcome": "ok", "id": "c1-abc"}

        err = StringIO()
        with mock.patch.object(rsdev, "call", fake_call), mock.patch("sys.stderr", err):
            with redirect_stdout(StringIO()):
                code = rsdev.main([*argv, "--port", "1"])
        return code, err.getvalue(), paths

    def test_eval_and_reset_refuse_a_daemon_from_before_the_eval_kinds(self):
        old = {"up": True, "pid": 1234}  # what a daemon from before eval reports: no kinds
        for argv, what in ((["eval", "1 + 1"], "eval"), (["eval", "--reset"], "eval --reset")):
            with self.subTest(argv):
                code, err, paths = self.cli_against(old, *argv)
                self.assertEqual(code, 2)
                self.assertEqual(paths, ["/cli/status"])  # nothing queued
                self.assertIn(f"predates `rsdev.py {what}`", err)
                self.assertIn("scripts/rsdev.py stop && scripts/rsdev.py start", err)

    def test_eval_goes_ahead_when_the_daemon_lists_its_kind(self):
        code, _, paths = self.cli_against({"kinds": ["exec", "eval", "reset"]}, "eval", "1")
        self.assertEqual((code, paths), (0, ["/cli/status", "/cli/exec"]))

    def test_exec_does_not_check_the_kinds(self):
        code, _, paths = self.cli_against({"up": True}, "exec", "plist")
        self.assertEqual((code, paths), (0, ["/cli/exec"]))


class TeeTests(DaemonCase):
    def events(self, query=""):
        return get(self.port, "/cli/events" + query)["events"]

    def test_lines_become_numbered_log_events_and_are_persisted(self):
        self.sync(events=[{"t": 1, "name": "A", "payload": 1}])
        lines = [{"t": 7, "level": "print", "text": "a"}, {"t": 8, "level": "error", "text": "b"}]
        status, body = post(self.port, "/tee", tee_body(lines=lines))
        self.assertEqual((status, body), (200, ""))
        got = self.events("?name=Log")
        self.assertEqual([e["n"] for e in got], [2, 3])
        self.assertEqual(
            got[1],
            {"t": 8, "name": "Log", "payload": {"plugin": "demo", "level": "error", "text": "b"}, "n": 3, "session": "t1"},
        )
        path = self.out / "rsdev" / "events" / "tee" / "demo" / "t1.jsonl"
        self.assertEqual([json.loads(ln) for ln in path.read_text().splitlines()], got)

    def test_bad_bodies_are_400_and_apply_nothing(self):
        ok = {"t": 1, "level": "log", "text": "x"}
        for bad in (
            [],
            tee_body(schema="1"),
            tee_body(plugin="a/b"),
            tee_body(session=3),
            tee_body(seq="1"),
            tee_body(dropped=-1),
            tee_body(dropped="2"),
            tee_body(lines="x"),
            tee_body(lines=["x"]),
            tee_body(lines=[ok, {**ok, "t": "1"}]),
            tee_body(lines=[ok, {**ok, "t": 1.5}]),
            tee_body(lines=[ok, {**ok, "level": "warn"}]),
            tee_body(lines=[ok, {**ok, "text": 3}]),
        ):
            self.assertEqual(post(self.port, "/tee", bad)[0], 400, bad)
        self.assertEqual(self.events(), [])
        self.assertFalse((self.out / "rsdev").exists())

    def test_dropped_growth_adds_a_marker_once(self):
        post(self.port, "/tee", tee_body(dropped=3))
        post(self.port, "/tee", tee_body(seq=2, dropped=3))
        post(self.port, "/tee", tee_body(seq=3, dropped=4))
        marks = [e for e in self.events("?name=Log") if e["payload"]["level"] == "dropped"]
        self.assertEqual([(m["payload"]["text"], m["t"]) for m in marks], [("3 lines lost", 7), ("1 lines lost", 7)])
        self.assertEqual({m["payload"]["plugin"] for m in marks}, {"demo"})
        self.assertEqual(self.server.state.status()["dropped"], 4)

    def test_ambiguous_names_get_separate_files(self):
        post(self.port, "/tee", tee_body(plugin="a-b", session="c"))
        post(self.port, "/tee", tee_body(plugin="a", session="b-c"))
        base = self.out / "rsdev" / "events" / "tee"
        self.assertTrue((base / "a-b" / "c.jsonl").is_file())
        self.assertTrue((base / "a" / "b-c.jsonl").is_file())

    def test_deeply_nested_body_is_a_400(self):
        self.assertEqual(post(self.port, "/tee", b"[" * 100_000, cli=False)[0], 400)
        self.assertEqual(post(self.port, "/tee", tee_body())[0], 200)  # the handler survived

    def test_overlong_integer_body_is_a_400(self):
        # json.loads raises a bare ValueError (not JSONDecodeError) past the int digit limit.
        self.assertEqual(post(self.port, "/tee", b"1" * 5000, cli=False)[0], 400)
        self.assertEqual(post(self.port, "/tee", tee_body())[0], 200)

    def test_tee_routes_share_the_browser_guards(self):
        self.assertEqual(post(self.port, "/tee", tee_body(), {"Origin": "http://evil"})[0], 403)
        self.assertEqual(post(self.port, "/tee", tee_body(), {"Host": "evil.test"})[0], 403)
        self.assertEqual(post(self.port, "/tee", b"{", cli=False)[0], 400)
        # Same Content-Length rules as /record: refused before the body is read.
        self.assertEqual(RecordTests.raw_post(self, "/tee", str(rsdev.MAX_BODY + 1)), 413)
        self.assertEqual(RecordTests.raw_post(self, "/tee", "-1"), 400)


class LogsTests(CliCase):
    def seed(self):
        self.sync(events=[{"t": 1, "name": "A", "payload": 1}])
        lines = [
            {"t": 1, "level": "print", "text": "one"},
            {"t": 2, "level": "error", "text": "two\nmore"},
        ]
        post(self.port, "/tee", tee_body(lines=lines))
        post(self.port, "/tee", tee_body(plugin="other", session="t2", lines=lines[:1]))
        self.sync(seq=2, events=[{"t": 3, "name": "Log", "payload": {"plugin": "bridged", "level": "log", "text": "z"}}])

    def logs(self, *argv):
        t, out = self.run_cli("logs", *argv)
        t.join()
        self.assertEqual(out["code"], 0)
        return out["stdout"]

    def test_formats_log_events_only(self):
        self.seed()
        self.assertEqual(
            self.logs().splitlines(),
            ["2 [demo] print: one", "3 [demo] error: two", "    more", "4 [other] print: one", "5 [bridged] log: z"],
        )

    def test_plugin_filter_and_since(self):
        self.seed()
        self.assertEqual(self.logs("--plugin", "other").splitlines(), ["4 [other] print: one"])
        self.assertEqual(self.logs("--since", "4").splitlines(), ["5 [bridged] log: z"])

    def test_lost_lines_show_in_logs_for_their_plugin_only(self):
        self.seed()
        post(self.port, "/tee", tee_body(seq=2, dropped=2, lines=[]))
        post(self.port, "/tee", tee_body(plugin="other", session="t2", seq=2, dropped=1, lines=[]))
        shown = self.logs("--plugin", "demo").splitlines()
        self.assertEqual(shown[-1], "6 [demo] dropped: 2 lines lost")
        self.assertNotIn("[other] dropped", "\n".join(shown))
        self.assertIn("[other] dropped: 1 lines lost", self.logs())

    def test_json_prints_the_raw_events(self):
        self.seed()
        events = [json.loads(ln) for ln in self.logs("--json", "--plugin", "demo").splitlines()]
        self.assertEqual([e["n"] for e in events], [2, 3])
        self.assertEqual(events[0]["payload"], {"plugin": "demo", "level": "print", "text": "one"})

    def test_follow_reuses_the_events_poll_and_asks_for_log_events(self):
        log = lambda n, plugin: {"n": n, "name": "Log", "payload": {"plugin": plugin, "level": "log", "text": "t"}}  # noqa: E731
        replies = [{"events": [log(1, "a"), log(2, "b")], "last": 2, "run": "r"}]
        paths = []

        def fake_call(args, path, payload=None, timeout=5.0):
            paths.append(path)
            if not replies:
                raise KeyboardInterrupt
            return replies.pop(0)

        args = SimpleNamespace(port=1, since=0, follow=True, plugin="b", json=False)
        out = StringIO()
        with mock.patch.object(rsdev, "call", fake_call), redirect_stdout(out):
            self.assertEqual(rsdev.cmd_logs(args), 0)
        self.assertEqual(out.getvalue().splitlines(), ["2 [b] log: t"])
        self.assertEqual(paths, ["/cli/events?since=0&wait=25&name=Log", "/cli/events?since=2&wait=25&name=Log"])


class EventsTests(DaemonCase):
    def test_a_sync_lands_in_the_session_file_in_order(self):
        self.sync(dropped=2, events=[{"t": i, "name": "E", "payload": i} for i in (5, 6, 7)])
        lines = (self.out / "rsdev" / "events" / "b1.jsonl").read_text().splitlines()
        stored = [json.loads(line) for line in lines]
        self.assertEqual([e["n"] for e in stored], [1, 2, 3, 4])
        self.assertEqual([e["name"] for e in stored], ["dropped", "E", "E", "E"])
        self.assertEqual(stored, get(self.port, "/cli/events")["events"])

    def seed(self):
        self.sync(
            events=[
                {"t": 1, "name": "A", "payload": 1},
                {"t": 2, "name": "B", "payload": 2},
                {"t": 3, "name": "A", "payload": 3},
            ]
        )

    def test_since_and_name_filters(self):
        self.seed()
        self.assertEqual([e["n"] for e in get(self.port, "/cli/events?since=1")["events"]], [2, 3])
        reply = get(self.port, "/cli/events?name=A")
        self.assertEqual([e["n"] for e in reply["events"]], [1, 3])
        self.assertEqual(reply["last"], 3)

    def test_follow_wakes_when_an_event_arrives(self):
        self.seed()
        out = {}

        def poll():
            out.update(get(self.port, "/cli/events?since=3&wait=10"))

        t = threading.Thread(target=poll)
        t.start()
        self.sync(seq=2, events=[{"t": 4, "name": "C", "payload": 4}])
        t.join()
        self.assertEqual([e["n"] for e in out["events"]], [4])

    def test_follow_times_out_empty(self):
        reply = get(self.port, "/cli/events?since=0&wait=0.1")
        self.assertEqual(reply, {"events": [], "last": 0, "run": self.server.state.run})

    def test_follow_restarts_numbering_when_the_daemon_run_changes(self):
        ev = lambda n: {"n": n, "name": "A"}  # noqa: E731
        replies = [
            {"events": [ev(5)], "last": 5, "run": "old"},
            {"events": [], "last": 5, "run": "new"},  # new daemon: `last` is the stale since
            {"events": [ev(1)], "last": 1, "run": "new"},
        ]
        paths = []

        def fake_call(args, path, payload=None, timeout=5.0):
            paths.append(path)
            if not replies:
                raise KeyboardInterrupt
            return replies.pop(0)

        args = SimpleNamespace(port=1, since=0, follow=True, name=None)
        err, out = StringIO(), StringIO()
        with mock.patch.object(rsdev, "call", fake_call), mock.patch("sys.stderr", err), redirect_stdout(out):
            self.assertEqual(rsdev.cmd_events(args), 0)
        self.assertIn("daemon restarted; numbering restarted", err.getvalue())
        self.assertEqual([json.loads(ln)["n"] for ln in out.getvalue().splitlines()], [5, 1])
        self.assertEqual([p.split("&")[0] for p in paths[:4]], ["/cli/events?since=0", "/cli/events?since=5", "/cli/events?since=0", "/cli/events?since=1"])

    def test_stale_since_reply_from_a_new_run_is_not_printed(self):
        replies = [
            {"events": [{"n": 5}], "last": 5, "run": "old"},
            {"events": [{"n": 9, "name": "stale"}], "last": 9, "run": "new"},
            {"events": [{"n": 1}], "last": 1, "run": "new"},
        ]

        def fake_call(args, path, payload=None, timeout=5.0):
            if not replies:
                raise KeyboardInterrupt
            return replies.pop(0)

        args = SimpleNamespace(port=1, since=0, follow=True, name=None)
        out = StringIO()
        with (
            mock.patch.object(rsdev, "call", fake_call),
            mock.patch("sys.stderr", StringIO()),
            redirect_stdout(out),
        ):
            rsdev.cmd_events(args)
        printed = [json.loads(ln)["n"] for ln in out.getvalue().splitlines()]
        self.assertEqual(printed, [5, 1])

    def test_non_follow_exits_2_when_the_daemon_is_down(self):
        self.server.shutdown()
        self.server.socket.close()
        args = SimpleNamespace(port=self.port, since=0, follow=False, name=None)
        with mock.patch("sys.stderr", StringIO()):
            self.assertEqual(rsdev.cmd_events(args), 2)



class FollowRestartTests(unittest.TestCase):
    """--follow against real daemon processes, since only a dead process drops the long poll."""

    def start_daemon(self, port, out):
        proc = subprocess.Popen(
            [sys.executable, str(SCRIPT), "daemon", "--port", str(port), "--out", str(out)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.addCleanup(lambda: (proc.poll() is None and proc.kill(), proc.wait()))
        for _ in range(100):
            try:
                get(port, "/cli/status")
                return proc
            except OSError:
                time.sleep(0.05)
        self.fail("daemon did not come up")

    def wait_for(self, cond):
        for _ in range(300):
            if cond():
                return
            time.sleep(0.05)
        self.fail("condition never became true")

    def test_follow_survives_a_real_daemon_restart(self):
        with tempfile.TemporaryDirectory() as tmp, socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
            probe.close()
            out_dir = Path(tmp)
            first = self.start_daemon(port, out_dir)
            post(port, "/bridge/sync", sync_body(events=[{"t": 1, "name": "OLD", "payload": 1}]))
            args = SimpleNamespace(port=port, since=0, follow=True, name=None)
            out, err = StringIO(), StringIO()
            result = []
            stop = threading.Event()
            real_call = rsdev.call

            def call_until_stopped(*a, **kw):
                if stop.is_set():
                    raise KeyboardInterrupt  # the follower's clean exit
                return real_call(*a, **kw)

            with (
                mock.patch("sys.stderr", err),
                mock.patch.object(rsdev, "call", call_until_stopped),
                redirect_stdout(out),
            ):
                t = threading.Thread(target=lambda: result.append(rsdev.cmd_events(args)), daemon=True)
                t.start()
                self.wait_for(lambda: len(out.getvalue().splitlines()) >= 1)
                first.terminate()
                first.wait()
                self.wait_for(lambda: "retrying" in err.getvalue())
                second = self.start_daemon(port, out_dir)
                post(port, "/bridge/sync", sync_body(session="b2", events=[{"t": 9, "name": "NEW", "payload": 9}]))
                self.wait_for(lambda: len(out.getvalue().splitlines()) >= 2)
                time.sleep(0.5)  # a duplicate would show up by now
                self.assertEqual(result, [])  # still following; the daemon thread dies with the process
                # Killing the daemon drops the long poll; the next call then stops the follower
                # before the patches are undone, so it cannot write to the real stderr.
                logged = err.getvalue()  # the shutdown below adds a second "retrying"
                stop.set()
                second.kill()
                t.join(timeout=10)
                self.assertFalse(t.is_alive(), "follower did not exit")
            lines = [json.loads(ln) for ln in out.getvalue().splitlines()]
            self.assertEqual([(e["n"], e["name"]) for e in lines], [(1, "OLD"), (1, "NEW")])
            self.assertEqual(logged.count("daemon not reachable; retrying"), 1)
            self.assertIn("daemon reachable again", logged)
            self.assertIn("daemon restarted; numbering restarted", logged)
            self.assertEqual(result, [0])


class EscapeTests(unittest.TestCase):
    def test_fixed_vector(self):
        # The same vector is asserted against the bridge's unescape in tests/dev-bridge/protocol_spec.lua.
        raw = "say a\tb\nc\\d\re \\t"
        escaped = "say a\\tb\\nc\\\\d\\re \\\\t"
        self.assertEqual(rsdev.escape_arg(raw), escaped)
        self.assertEqual(rsdev.unescape_arg(escaped), raw)

    def test_round_trip(self):
        for text in ("", "plain", "a\tb", "a\nb", "a\rb", "\\", "\\t", "\\\t\n\r\\n"):
            escaped = rsdev.escape_arg(text)
            self.assertNotRegex(escaped, r"[\t\n\r]")
            self.assertEqual(rsdev.unescape_arg(escaped), text)


RS_CLASS = 'WM_CLASS(STRING) = "rs2client", "RuneScape"'
VIVALDI_CLASS = 'WM_CLASS(STRING) = "vivaldi-stable", "Vivaldi-stable"'


def fake_x(classes, viewable=True, active="0x10", desktop=3, fail=(), gone=()):
    """A stand-in for rsdev.run_tool: `classes` maps window id -> WM_CLASS line. Records argvs."""
    calls = []

    def run(argv):
        calls.append(argv)
        out = ""
        if argv[0] in fail:
            return SimpleNamespace(returncode=1, stdout="", stderr=f"{argv[0]} broke")
        if argv[:2] == ["xprop", "-root"]:
            prop = argv[2]
            if prop == "_NET_CLIENT_LIST":
                out = "_NET_CLIENT_LIST(WINDOW): window id # " + ", ".join(classes)
            elif prop == "_NET_ACTIVE_WINDOW":
                out = f"_NET_ACTIVE_WINDOW(WINDOW): window id # {active}"
            else:
                out = '_NET_DESKTOP_NAMES(UTF8_STRING) = "1: web", "2: slack", "3: dev", "4"'
        elif argv[0] == "xprop" and argv[2] in gone:
            return SimpleNamespace(returncode=1, stdout="", stderr="BadWindow")
        elif argv[0] == "xprop":
            out = classes[argv[2]] if argv[3] == "WM_CLASS" else f"_NET_WM_DESKTOP(CARDINAL) = {desktop}"
        elif argv[0] == "xwininfo":
            out = "  Map State: " + ("IsViewable" if viewable else "IsUnviewable")
        elif argv[0] == "maim":
            Path(argv[-1]).write_bytes(b"png")
        elif argv[0] == "magick":
            Path(argv[-1]).write_bytes(b"jpg")
        return SimpleNamespace(returncode=0, stdout=out, stderr="")

    run.calls = calls
    return run


def shot_opts(out, **over):
    base = dict(window=None, region=None, max=1600, out=Path(out), count=1, every=1.0, delay=0.0)
    return SimpleNamespace(**{**base, **over})


class ShotParseTests(unittest.TestCase):
    def test_region(self):
        self.assertEqual(rsdev.region_arg("200x100+0+30"), "200x100+0+30")
        for bad in ("0x100+0+0", "100x0+0+0", "100x100+-1+0", "100x100", "100x100+1", "axb+0+0", "-1x5+0+0", "１０x10+0+0", "10x10+0+０"):
            with self.subTest(bad), self.assertRaises(rsdev.argparse.ArgumentTypeError):
                rsdev.region_arg(bad)

    def test_option_ranges(self):
        for argv in (["--count", "0"], ["--count", "101"], ["--every", "0"], ["--every", "nan"], ["--max", "-1"]):
            with self.subTest(argv), mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
                rsdev.main(["shot", *argv])
        with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
            rsdev.main(["shot", "--window", "5a0002d"])
        with mock.patch("sys.stderr", StringIO()), self.assertRaises(SystemExit):
            rsdev.main(["shot", "--window", "0x１a"])

    def test_shot_options_need_shot_on_exec(self):
        for argv in (["--window", "0x5"], ["--region", "1x1+0+0"], ["--max", "1600"], ["--shot-delay", "0"]):
            with self.subTest(argv), mock.patch("sys.stderr", StringIO()) as err:
                with self.assertRaises(SystemExit) as caught:
                    rsdev.main(["exec", *argv, "x"])
                self.assertEqual(caught.exception.code, 2)
                self.assertIn("only apply with --shot", err.getvalue())

    def test_property_parsers(self):
        self.assertEqual(rsdev.parse_window_ids("_NET_CLIENT_LIST(WINDOW): window id # 0x1, 0x5a0002d"), ["0x1", "0x5a0002d"])
        self.assertEqual(rsdev.parse_window_ids("_NET_CLIENT_LIST:  not found."), [])
        self.assertEqual(rsdev.parse_cardinal("_NET_WM_DESKTOP(CARDINAL) = 3\n"), 3)
        self.assertIsNone(rsdev.parse_cardinal("_NET_WM_DESKTOP:  not found."))
        self.assertEqual(rsdev.parse_strings('x = "1: web", "3: dev"'), ["1: web", "3: dev"])

    def test_stamp_has_milliseconds(self):
        self.assertRegex(rsdev.shot_stamp(1700000000.1239), r"^\d{8}-\d{6}-123$")
        self.assertNotEqual(rsdev.shot_stamp(1700000000.1), rsdev.shot_stamp(1700000000.2))

    def test_max_picks_format(self):
        d = Path("/s")
        self.assertEqual(rsdev.shot_paths(d, "T", 1, 1600), [d / "T.jpg"])
        self.assertEqual(rsdev.shot_paths(d, "T", 1, 0), [d / "T.png"])
        self.assertEqual(rsdev.shot_paths(d, "T", 3, 0), [d / f"T-0{i}.png" for i in (1, 2, 3)])
        self.assertEqual(rsdev.shot_paths(d, "T", 100, 1600)[-1], d / "T-100.jpg")
        self.assertEqual(rsdev.convert_args("a.png", "b.jpg", 1600)[1:], ["a.png", "-resize", "1600x1600>", "-quality", "85", "b.jpg"])


class ShotTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.err = StringIO()

    def shoot(self, run, **over):
        """take_shots with the X layer stubbed and every tool 'installed'; (paths printed, error)."""
        out = StringIO()
        with (
            mock.patch.object(rsdev, "run_tool", run),
            mock.patch("shutil.which", return_value="/bin/x"),
            mock.patch("sys.stderr", self.err),
            mock.patch("time.sleep"),
            redirect_stdout(out),
        ):
            try:
                rsdev.take_shots(shot_opts(self.tmp.name, **over))
                error = None
            except rsdev.ShotError as e:
                error = e
        return out.getvalue().split(), error

    def test_selects_the_client_by_class_not_title(self):
        run = fake_x({"0x10": VIVALDI_CLASS, "0x20": RS_CLASS})
        paths, err = self.shoot(run)
        self.assertIsNone(err)
        maim = [c for c in run.calls if c[0] == "maim"][0]
        self.assertEqual(maim[:4], ["maim", "-u", "-i", "0x20"])
        self.assertEqual(len(paths), 1)
        self.assertTrue(paths[0].endswith(".jpg") and Path(paths[0]).read_bytes() == b"jpg")
        self.assertEqual(list(Path(paths[0]).parent.glob("*.tmp.png")), [])  # temp deleted

    def test_vanished_window_is_skipped(self):
        run = fake_x({"0x10": VIVALDI_CLASS, "0x20": RS_CLASS}, gone=("0x10",))
        paths, err = self.shoot(run)
        self.assertIsNone(err)
        maim = [c for c in run.calls if c[0] == "maim"][0]
        self.assertEqual(maim[:4], ["maim", "-u", "-i", "0x20"])

    def test_no_match_and_several(self):
        _, err = self.shoot(fake_x({"0x10": VIVALDI_CLASS}))
        self.assertEqual(err.code, 2)
        self.assertIn("not found", str(err))
        _, err = self.shoot(fake_x({"0x10": RS_CLASS, "0x20": RS_CLASS}))
        self.assertEqual(err.code, 2)
        self.assertIn("0x10, 0x20", str(err))
        self.assertIn("--window", str(err))

    def test_window_override_skips_lookup(self):
        run = fake_x({})
        _, err = self.shoot(run, window="0x99", active="0x99")
        self.assertIsNone(err)
        self.assertNotIn(["xprop", "-root", "_NET_CLIENT_LIST"], run.calls)

    def test_hidden_window_is_refused_without_capturing(self):
        run = fake_x({"0x20": RS_CLASS}, viewable=False, desktop=2)
        paths, err = self.shoot(run)
        self.assertEqual(err.code, 2)
        self.assertIn('"3: dev"', str(err))
        self.assertEqual(paths, [])
        self.assertNotIn("maim", [c[0] for c in run.calls])

    def test_workspace_without_a_name(self):
        with mock.patch.object(rsdev, "run_tool", fake_x({}, desktop=9)):
            self.assertIn("number 9", rsdev.workspace_hint("0x1"))

    def test_warns_when_not_focused(self):
        _, err = self.shoot(fake_x({"0x20": RS_CLASS}, active="0x30"))
        self.assertIsNone(err)  # still captured
        self.assertIn("not the active window", self.err.getvalue())

    def test_no_warning_when_focused(self):
        self.shoot(fake_x({"0x20": RS_CLASS}, active="0x00000020"))
        self.assertEqual(self.err.getvalue(), "")

    def test_max_zero_keeps_png_and_region_goes_to_maim(self):
        run = fake_x({"0x20": RS_CLASS}, active="0x20")
        paths, err = self.shoot(run, max=0, region="10x20+3+4")
        self.assertIsNone(err)
        self.assertTrue(paths[0].endswith(".png"))
        maim = [c for c in run.calls if c[0] == "maim"][0]
        self.assertEqual(maim[4:6], ["-g", "10x20+3+4"])
        self.assertNotIn("magick", [c[0] for c in run.calls])

    def test_capture_failure_shows_tool_stderr(self):
        _, err = self.shoot(fake_x({"0x20": RS_CLASS}, active="0x20", fail=("maim",)))
        self.assertEqual(err.code, 1)
        self.assertIn("maim broke", str(err))

    def test_max_zero_failed_maim_leaves_no_file(self):
        _, err = self.shoot(fake_x({"0x20": RS_CLASS}, active="0x20", fail=("maim",)), max=0)
        self.assertEqual(err.code, 1)
        self.assertEqual(list(Path(self.tmp.name).rglob("*.png")), [])

    def test_convert_failure_shows_stderr_and_leaves_no_file(self):
        _, err = self.shoot(fake_x({"0x20": RS_CLASS}, active="0x20", fail=("magick",)))
        self.assertEqual(err.code, 1)
        self.assertIn("magick broke", str(err))
        self.assertEqual([p for p in Path(self.tmp.name).rglob("*") if p.is_file()], [])

    def test_interrupt_leaves_no_files(self):
        for tool in ("maim", "magick"):
            inner = fake_x({"0x20": RS_CLASS}, active="0x20")

            def run(argv, inner=inner, tool=tool):
                res = inner(argv)  # the tool has written its (partial) output when Ctrl-C lands
                if argv[0] == tool:
                    raise KeyboardInterrupt
                return res

            with self.subTest(tool), mock.patch.object(rsdev, "run_tool", run), mock.patch(
                "shutil.which", return_value="/bin/x"
            ), mock.patch("sys.stderr", self.err), redirect_stdout(StringIO()):
                self.assertEqual(rsdev.cmd_shot(shot_opts(self.tmp.name)), 130)
            self.assertEqual([p for p in Path(self.tmp.name).rglob("*") if p.is_file()], [])

    def test_unknown_window_exits_2(self):
        def run(argv):
            if argv[0] == "xwininfo":
                err = "xwininfo: Bad Drawable\n  X Error: 9\nxwininfo: error: No such window 0xdeadbee"
                return SimpleNamespace(returncode=1, stdout="", stderr=err)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        _, err = self.shoot(run, window="0xdeadbee")
        self.assertEqual(err.code, 2)
        self.assertIn("0xdeadbee not found", str(err))
        self.assertIn("No such window", str(err))

    def test_max_zero_does_not_need_magick(self):
        with mock.patch("shutil.which", lambda t: None if t == "magick" else "/bin/x"):
            run = fake_x({"0x20": RS_CLASS}, active="0x20")
            with mock.patch.object(rsdev, "run_tool", run), redirect_stdout(StringIO()):
                rsdev.take_shots(shot_opts(self.tmp.name, max=0))  # no ShotError
            with mock.patch.object(rsdev, "run_tool", run), self.assertRaises(rsdev.ShotError) as cm:
                rsdev.take_shots(shot_opts(self.tmp.name))
        self.assertIn("magick", str(cm.exception))

    def test_missing_tool_names_it(self):
        with mock.patch("shutil.which", lambda t: None if t == "maim" else "/bin/x"):
            with self.assertRaises(rsdev.ShotError) as cm:
                rsdev.take_shots(shot_opts(self.tmp.name))
        self.assertEqual(cm.exception.code, 2)
        self.assertIn("maim", str(cm.exception))
        self.assertIn("direnv", str(cm.exception))

    def test_series_schedule(self):
        clock = [100.0]
        sleeps = []

        def sleep(s):
            sleeps.append(round(s, 3))
            clock[0] += s

        run = fake_x({"0x20": RS_CLASS}, active="0x20")
        inner = run

        def slow(argv):  # each maim takes 0.4 s, the first 2.5 s (an overrun)
            if argv[0] == "maim":
                clock[0] += 2.5 if not sleeps_after_first[0] else 0.4
                sleeps_after_first[0] = True
            return inner(argv)

        sleeps_after_first = [False]
        with mock.patch("time.sleep", sleep), mock.patch("time.monotonic", lambda: clock[0]):
            out = StringIO()
            with (
                mock.patch.object(rsdev, "run_tool", slow),
                mock.patch("shutil.which", return_value="/bin/x"),
                redirect_stdout(out),
            ):
                rsdev.take_shots(shot_opts(self.tmp.name, count=3, every=1.0, delay=0.5))
        paths = out.getvalue().split()
        self.assertEqual([Path(p).stem[-3:] for p in paths], ["-01", "-02", "-03"])
        # delay, then no wait after the overrunning first capture, then the 0.6 s left of 1.0
        self.assertEqual(sleeps, [0.5, 0.6])

    def test_window_hidden_during_delay_is_not_captured(self):
        run = fake_x({"0x20": RS_CLASS}, active="0x20")
        views = iter([False])  # the window is gone by the time --delay has slept

        def hiding(argv):
            res = run(argv)
            if argv[0] == "xwininfo":
                res.stdout = "  Map State: " + ("IsViewable" if next(views) else "IsUnviewable")
            return res

        paths, error = self.shoot(hiding, delay=5.0, count=2)
        self.assertEqual(error.code, 2)
        self.assertIn("is not visible", str(error))
        self.assertEqual(paths, [])
        self.assertNotIn("maim", [c[0] for c in run.calls])

    def test_window_hidden_mid_series_stops_the_series(self):
        run = fake_x({"0x20": RS_CLASS}, active="0x20")
        views = iter([True, False])

        def hiding(argv):
            res = run(argv)
            if argv[0] == "xwininfo":
                res.stdout = "  Map State: " + ("IsViewable" if next(views) else "IsUnviewable")
            return res

        paths, error = self.shoot(hiding, count=3)
        self.assertEqual(error.code, 2)
        self.assertEqual(len(paths), 1)
        self.assertEqual([c[0] for c in run.calls].count("maim"), 1)

    def test_check_visible_messages(self):
        def gone(argv):
            return SimpleNamespace(returncode=1, stdout="", stderr="xwininfo: error: No such window with id 0xdeadbee.\n")

        with mock.patch.object(rsdev, "run_tool", gone), self.assertRaises(rsdev.ShotError) as caught:
            rsdev.check_visible("0xdeadbee")
        msg = str(caught.exception)
        self.assertIn("not found (xwininfo: error: No such window", msg)
        self.assertEqual(msg.count("xwininfo:"), 1)
        run = fake_x({"0x20": RS_CLASS}, viewable=False)
        with mock.patch.object(rsdev, "run_tool", run), self.assertRaises(rsdev.ShotError) as caught:
            rsdev.check_visible("0x20")
        self.assertTrue(str(caught.exception).startswith("window 0x20 is not visible"))

    def test_cmd_shot_exit_codes(self):
        with mock.patch.object(rsdev, "take_shots", side_effect=rsdev.ShotError(2, "nope")), mock.patch("sys.stderr", self.err):
            self.assertEqual(rsdev.cmd_shot(shot_opts(self.tmp.name)), 2)
        with mock.patch.object(rsdev, "take_shots"):
            self.assertEqual(rsdev.cmd_shot(shot_opts(self.tmp.name)), 0)
        with mock.patch.object(rsdev, "take_shots", side_effect=KeyboardInterrupt):
            self.assertEqual(rsdev.cmd_shot(shot_opts(self.tmp.name)), 130)


class ExecShotTests(unittest.TestCase):
    def merge(self, exec_code, shot_code):
        args = SimpleNamespace(shot=True, window=None, region=None, max=1600, out=Path("/o"), shot_delay=0.0)
        with (
            mock.patch.object(rsdev, "exec_command", return_value=exec_code),
            mock.patch.object(rsdev, "cmd_shot", return_value=shot_code) as shot,
        ):
            return rsdev.cmd_exec(args), shot.called

    def test_exit_code_merge(self):
        self.assertEqual(self.merge(0, 0), (0, True))
        self.assertEqual(self.merge(0, 1), (4, True))
        self.assertEqual(self.merge(0, 2), (4, True))
        self.assertEqual(self.merge(1, 0), (1, True))  # a plugin error still gets a shot
        self.assertEqual(self.merge(1, 2), (1, True))  # exec's code stands
        self.assertEqual(self.merge(0, 130), (130, True))  # Ctrl-C during the shot

    def test_no_shot_without_a_result(self):
        self.assertEqual(self.merge(2, 0), (2, False))  # never delivered
        self.assertEqual(self.merge(3, 0), (3, False))  # outcome unknown

    def test_no_shot_flag_no_shot(self):
        args = SimpleNamespace(shot=False)
        with mock.patch.object(rsdev, "exec_command", return_value=0), mock.patch.object(rsdev, "cmd_shot") as shot:
            self.assertEqual(rsdev.cmd_exec(args), 0)
        shot.assert_not_called()


if __name__ == "__main__":
    unittest.main()
