"""Tests for scripts/rsdev.py, run by scripts/check-lua.sh:

    python3 -m unittest scripts/test_rsdev.py

Each test runs a real daemon server on an ephemeral port, writing to a temp dir, and talks to it
over HTTP the way the recorder, the bridge plugin and the CLI do."""

import importlib.util
import json
import os
import tempfile
import threading
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
        args = SimpleNamespace(port=self.port, command=["x", "y"], timeout=0.2)
        err = StringIO()
        with redirect_stdout(StringIO()), mock.patch("sys.stderr", err):
            self.assertEqual(rsdev.cmd_exec(args), 2)  # nobody polling: withdrawn
            args.port = 1  # nothing listens there
            self.assertEqual(rsdev.cmd_exec(args), 2)


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


class EventsTests(DaemonCase):
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


class EscapeTests(unittest.TestCase):
    def test_round_trip(self):
        for text in ("", "plain", "a\tb", "a\nb", "a\rb", "\\", "\\t", "\\\t\n\r\\n"):
            escaped = rsdev.escape_arg(text)
            self.assertNotRegex(escaped, r"[\t\n\r]")
            self.assertEqual(rsdev.unescape_arg(escaped), text)


if __name__ == "__main__":
    unittest.main()
