"""Tests for scripts/var-dump-changes.py, run by scripts/check.sh:

    python3 -m unittest scripts/test_var_dump_changes.py

The receiver may be mid-append when the change log is read, so a torn last line must not abort."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("var-dump-changes.py")
spec = importlib.util.spec_from_file_location("var_dump_changes", SCRIPT)
changes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changes)


class ReadJsonl(unittest.TestCase):
    def test_skips_torn_and_non_object_lines_and_keeps_objects(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "changes.jsonl"
            path.write_text('{"seq": 1}\n5\n\n{"seq": 2}\n{"seq": 3, "na')
            with contextlib.redirect_stderr(io.StringIO()) as err:
                rows = changes.read_jsonl(path)
        self.assertEqual(rows, [{"seq": 1}, {"seq": 2}])
        self.assertEqual(err.getvalue().count("skipping line that is not a JSON object"), 2)
