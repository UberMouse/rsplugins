"""Tests for scripts/recording-sanitise.py, run by scripts/check.sh:

    python3 -m unittest scripts/test_recording_sanitise.py

Each test writes a small session whose player is "Zoë X" (a non-ASCII name, with a no-break
space as RS display names have) and sanitises it."""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).with_name("recording-sanitise.py")
spec = importlib.util.spec_from_file_location("recording_sanitise", SCRIPT)
sanitiser = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sanitiser)

NAME = "Zoë X"
HEADER = {"k": "session", "schema": 1, "plugin": "t", "session": "s", "started": 0}


def chat(t, message, sender="", chat_type=109):
    return {
        "t": t, "k": "event", "name": "ChatMessage",
        "payload": {"chatMessage": message, "senderNameUnfiltered": sender,
                    "senderNameFiltered": sender, "senderNameSimple": sender,
                    "chatType": chat_type, "timestamp": 1},
        "op": {"op": "chat", "message": message, "chatType": chat_type, "sender": sender},
    }


def session(*extra):
    return [HEADER,
            {"t": 0, "k": "read", "path": sanitiser.NAME_PATH, "v": NAME},
            {"t": 5, "k": "read", "path": "Some.table", "v": {"Zoë X": "zoë_x was here"}},
            chat(6, "You pick the target's pocket."),
            chat(6, "3 coins have been added to your money pouch."),
            chat(7, "Bob has logged in.", chat_type=0),
            chat(7, "Zoë X has logged in.", chat_type=0),
            chat(8, "hi Zoë X", sender="Bob", chat_type=2),
            *extra]


class CarriedStateTest(unittest.TestCase):
    def test_carries_the_latest_state_of_each_key_in_order(self):
        before = [
            {"t": 1, "k": "read", "path": "A", "v": 1},
            {"t": 1, "k": "perm", "permission": "x", "v": True},
            {"t": 2, "k": "db", "op": "GetInt", "key": "a", "v": 1},
            {"t": 2, "k": "read", "path": "A", "v": 2},  # the later read of A wins
            {"t": 3, "k": "db", "op": "Clear"},  # a and every other key set so far is now unset
            {"t": 4, "k": "db", "op": "SetBool", "key": "b", "value": False, "v": True},
            {"t": 4, "k": "db", "op": "Set", "key": "skipped", "value": 1, "v": False},
            {"t": 5, "k": "db", "op": "Delete", "key": "c"},
            {"t": 5, "k": "db", "op": "Get", "key": "e"},  # a plain Get: found nothing
            {"t": 6, "k": "db", "op": "GetInt", "key": "d", "v": 7},
            {"t": 6, "k": "perm", "permission": "y", "v": False},
        ]
        self.assertEqual(
            [
                {"t": 0, "k": "read", "path": "A", "v": 2},
                {"t": 0, "k": "perm", "permission": "x", "v": True},
                {"t": 0, "k": "perm", "permission": "y", "v": False},
                {"t": 0, "k": "db", "op": "Get", "key": "a"},
                {"t": 0, "k": "db", "op": "GetBool", "key": "b", "v": False},
                {"t": 0, "k": "db", "op": "Get", "key": "c"},
                {"t": 0, "k": "db", "op": "Get", "key": "e"},
                {"t": 0, "k": "db", "op": "GetInt", "key": "d", "v": 7},
            ],
            sanitiser.carried_state(before),
        )


class DedupReadsTest(unittest.TestCase):
    def test_drops_a_repeat_until_a_dropped_marker_resets_the_comparison(self):
        read = lambda t, v, path="p": {"t": t, "k": "read", "path": path, "v": v}  # noqa: E731
        entries = [
            read(1, {"b": 1, "a": 2}),
            read(2, {"a": 2, "b": 1}),  # same value, keys in another order: dropped
            read(2, 5, path="q"),  # another path is compared on its own
            {"t": 3, "k": "dropped", "n": 2},
            read(4, {"a": 2, "b": 1}),  # the same value again, after the gap: kept
            read(5, {"a": 2, "b": 1}),
            read(6, 9),
        ]
        self.assertEqual(
            [entries[0], entries[2], entries[3], entries[4], entries[6]],
            sanitiser.dedup_reads(entries),
        )


class SanitiseTest(unittest.TestCase):
    def run_script(self, lines, *flags, start=0, end=100):
        """Run main() on `lines`; returns (exit code, the output's text or None, stderr)."""
        with tempfile.TemporaryDirectory() as tmp:
            src, out = Path(tmp, "in.jsonl"), Path(tmp, "out.jsonl")
            src.write_text("".join(json.dumps(e) + "\n" for e in lines), encoding="utf-8")
            argv = ["sanitise", str(src), str(out), "--from", str(start), "--to", str(end),
                    *flags]
            err = StringIO()
            code = 0
            with mock.patch.object(sys, "argv", argv), redirect_stdout(StringIO()), \
                    redirect_stderr(err):
                try:
                    sanitiser.main()
                except SystemExit as e:
                    code = e.code if isinstance(e.code, int) else 1
                    err.write(str(e.code))
            text = out.read_text(encoding="utf-8") if out.exists() else None
            return code, text, err.getvalue()

    def entries(self, text):
        return [json.loads(line) for line in text.splitlines()]

    def test_replaces_a_non_ascii_name_everywhere(self):
        code, text, err = self.run_script(session())
        self.assertEqual(0, code, err)
        for needle in ("Zoë", "zoë", "Zo\\u00eb", "\\u00eb"):
            self.assertNotIn(needle, text)
        strings = [s for e in self.entries(text) for s in sanitiser.strings(e)]
        self.assertFalse([s for s in strings if "zoë" in s.lower()])
        self.assertIn("Fixture Player", strings)
        self.assertIn("Fixture Player was here", strings)

    def test_keeps_allowlisted_game_chat_and_redacts_the_rest(self):
        _, text, _ = self.run_script(session())
        chats = [(e["payload"]["chatType"], e["payload"]["chatMessage"], e["op"]["message"])
                 for e in self.entries(text) if e.get("name") == "ChatMessage"]
        self.assertEqual([
            (109, "You pick the target's pocket.", "You pick the target's pocket."),
            (109, "3 coins have been added to your money pouch.",
             "3 coins have been added to your money pouch."),
            # Naming a player: redacted, keeping its type and length.
            (0, "<redacted:18 chars>", "<redacted:18 chars>"),
            (0, "<redacted:20 chars>", "<redacted:20 chars>"),
            (2, "<redacted>", "<redacted>"),
        ], chats)
        player = [e for e in self.entries(text) if e.get("name") == "ChatMessage"][-1]
        self.assertEqual("<redacted>", player["payload"]["senderNameUnfiltered"])
        self.assertEqual("<redacted>", player["op"]["sender"])

    def test_refuses_to_write_if_one_string_keeps_the_name(self):
        real = sanitiser.replace_name

        def skip_one(text, pattern, placeholder):
            if text == "zoë_x was here":
                return text, 0
            return real(text, pattern, placeholder)

        with mock.patch.object(sanitiser, "replace_name", skip_one):
            code, text, err = self.run_script(session())
        self.assertNotEqual(0, code)
        self.assertIsNone(text)
        self.assertIn("nothing written", err)

    def test_deletes_a_written_file_that_has_the_name(self):
        # The check before writing misses it; the one on the file read back must not.
        real, calls = sanitiser.leaks, []

        def miss_first(pattern, text):
            calls.append(text)
            return 0 if len(calls) == 1 else real(pattern, text)

        with mock.patch.object(sanitiser, "replace_name", lambda t, p, r: (t, 0)), \
                mock.patch.object(sanitiser, "leaks", miss_first):
            code, text, err = self.run_script(session())
        self.assertNotEqual(0, code)
        self.assertIsNone(text)
        self.assertIn("deleted it", err)

    def test_finds_a_name_written_with_ascii_escapes(self):
        pattern = sanitiser.name_pattern({NAME})
        escaped = json.dumps({"a": "Zoë X said hi"}) + "\n"
        self.assertIn("\\u00eb", escaped)
        self.assertEqual(1, sanitiser.leaks(pattern, escaped))

    def test_refuses_a_window_with_dropped_entries_unless_allowed(self):
        lines = session({"t": 9, "k": "dropped", "n": 4})
        code, text, err = self.run_script(lines)
        self.assertNotEqual(0, code)
        self.assertIsNone(text)
        self.assertIn("lost 4 entries in 1 gap(s)", err)
        code, text, _ = self.run_script(lines, "--allow-dropped")
        self.assertEqual(0, code)
        self.assertIn({"t": 9, "k": "dropped", "n": 4}, self.entries(text))
        # Before the window, it would make the carried state wrong: refused too, and allowed
        # it comes in at t = 0.
        code, _, _ = self.run_script(lines, start=10)
        self.assertNotEqual(0, code)
        _, text, _ = self.run_script(lines, "--allow-dropped", start=10)
        self.assertIn({"t": 0, "k": "dropped", "n": 4}, self.entries(text))

    def test_a_short_name_needs_a_flag(self):
        lines = [HEADER, {"t": 0, "k": "read", "path": sanitiser.NAME_PATH, "v": "Bo"}]
        code, text, err = self.run_script(lines)
        self.assertNotEqual(0, code)
        self.assertIsNone(text)
        self.assertIn("under 4 characters", err)
        self.assertNotIn("Bo", err)
        code, _, _ = self.run_script(lines, "--short-name-ok")
        self.assertEqual(0, code)

    def test_trims_and_rebases_to_the_window(self):
        _, text, _ = self.run_script(session(), start=6, end=7)
        entries = self.entries(text)
        self.assertEqual(
            [
                {"k": "session", "schema": 1, "plugin": "t", "session": "s", "started": 0,
                 "window": [6, 7]},
                # Carried in at t = 0: the reads from before the window, name replaced.
                {"t": 0, "k": "read", "path": sanitiser.NAME_PATH, "v": "Fixture Player"},
                {"t": 0, "k": "read", "path": "Some.table",
                 "v": {"Fixture Player": "Fixture Player was here"}},
                chat(0, "You pick the target's pocket."),
                chat(0, "3 coins have been added to your money pouch."),
                chat(1, "<redacted:18 chars>", chat_type=0),
                chat(1, "<redacted:20 chars>", chat_type=0),
            ],
            entries,
        )

    def test_strips_object_addresses_before_deduping_reads(self):
        lines = [
            HEADER,
            {"t": 0, "k": "read", "path": sanitiser.NAME_PATH, "v": NAME},
            {"t": 1, "k": "read", "path": "Inv", "v": "sol.jag::InventoryProxy: 0x591c"},
            # Same object at another address: once stripped it repeats, so it is dropped.
            {"t": 2, "k": "read", "path": "Inv", "v": "sol.jag::InventoryProxy: 0x7f00"},
            {"t": 3, "k": "read", "path": "Nested", "v": ["a: 0x1f", {"k: 0x2": "b: 0xAB"}]},
        ]
        code, text, err = self.run_script(lines)
        self.assertEqual(0, code, err)
        self.assertNotIn("0x", text)
        self.assertEqual(
            [
                {"t": 1, "k": "read", "path": "Inv", "v": "sol.jag::InventoryProxy"},
                {"t": 3, "k": "read", "path": "Nested", "v": ["a", {"k": "b"}]},
            ],
            self.entries(text)[2:],  # past the header and the name read
        )

    def load(self, *patterns):
        """load_allowlist on a file of `patterns`."""
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "allowlist.txt")
            path.write_text("".join(p + "\n" for p in patterns), encoding="utf-8")
            return sanitiser.load_allowlist(path)

    def test_refuses_an_allowlist_pattern_not_anchored_as_a_whole(self):
        # ^You pick|.*$ is "^You pick" or ".*$", and the second matches any message.
        for pattern in ("^a|b$", "^You pick|.*$", "^(?:a)|b$", "^a$|^b$", "^a(?:^b)$",
                        "^a\\$", "a$", "^a", "^(?#\\))|.*$"):
            with self.subTest(pattern), self.assertRaises(sanitiser.Refused):
                self.load(pattern)

    def test_accepts_alternations_inside_a_group_and_escaped_or_in_a_class(self):
        # Most of these classes are free-form, so this checks the anchoring scan on its own.
        for pattern in ("^a(?:b|c)$", "^[|]$", "^a\\|b$", "^[]|$^]$", "^[^]|]$",
                        "^a(?#x|y\\))$", "^[\\]|]$"):
            with self.subTest(pattern):
                self.assertIsNone(sanitiser.unanchored(pattern))

    def test_refuses_an_allowlist_pattern_with_a_free_form_slot(self):
        for pattern in ("^(?:a|.*)$", "^.*$", "^\\w+ has logged in\\.$", "^[^x]*$",
                        "^(?s:.*)$", "^(?x: a | .* )$", "^(a)?(?(1)a|.*)$", "^(?P<n>a|.*)$",
                        "^(?i:a)$", "^\\d+$", "^\\bx$", "^[0-9A-Z]+$", "^(?:a)+$", "^a*$",
                        "^[0-9A-Fa-f]+ has logged in\\.$", "^[0-9A-Fa-f]{1,6}$",
                        "^[0-9A-Fa-f]$", "^[0-9A-Fa-f]{6}$", "^[0-9A-Fa-f]{6}?$",
                        "^(?:a[0-9A-Fa-f]{6})?$", "^[0-9A-Fa-f]{6} has logged in\\.$",
                        "^<col=[0-9A-Fa-f]{6}>?x$"):
            with self.subTest(pattern), self.assertRaises(sanitiser.Refused):
                self.load(pattern)

    def test_loads_the_allowlist_and_the_slots_it_allows(self):
        lines = [line for line in sanitiser.ALLOWLIST.read_text(encoding="utf-8").splitlines()
                 if line.strip() and not line.startswith("#")]
        self.assertEqual(len(lines), len(sanitiser.load_allowlist(sanitiser.ALLOWLIST)))
        for pattern in ("^[0-9,]+ x$", "^<col=[0-9A-Fa-f]{6}>a$", "^(?P<n>a|b)?c$",
                        "^a(?=b)(?!c)(?<=b)(?<!c)b$", "^a\\.b?$"):
            with self.subTest(pattern):
                self.assertEqual(1, len(self.load(pattern)))

    def test_refuses_a_dropped_line_without_a_tick(self):
        code, text, err = self.run_script(session({"k": "dropped", "n": 4}), "--allow-dropped")
        self.assertNotEqual(0, code)
        self.assertIsNone(text)
        self.assertIn("a dropped line has no integer t", err)

    def test_refuses_to_write_over_the_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            src = Path(tmp, "in.jsonl")
            original = "".join(json.dumps(e) + "\n" for e in session())
            src.write_text(original, encoding="utf-8")
            link = Path(tmp, "link.jsonl")
            os.link(src, link)
            for out in (src, Path(tmp, ".", "in.jsonl"), link):
                argv = ["sanitise", str(src), str(out), "--from", "0", "--to", "100"]
                with mock.patch.object(sys, "argv", argv), redirect_stdout(StringIO()), \
                        self.assertRaises(SystemExit) as caught:
                    sanitiser.main()
                self.assertIn("the output is the session file", str(caught.exception.code))
                self.assertEqual(original, src.read_text(encoding="utf-8"))

    def test_no_allowlist_pattern_matches_a_message_naming_a_player(self):
        for pattern in sanitiser.load_allowlist(sanitiser.ALLOWLIST):
            for message in ("Bob", "Bob 123", "Bob <col=ffffff>", "Bob has logged in.",
                            "Bead has logged in.", "Face", "Facade has logged in.",
                            "Bob coins have been added to your money pouch."):
                self.assertIsNone(pattern.fullmatch(message), pattern.pattern)


if __name__ == "__main__":
    unittest.main()
