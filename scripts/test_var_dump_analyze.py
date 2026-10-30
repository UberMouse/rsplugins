"""Tests for scripts/var-dump-analyze.py, run by scripts/check.sh:

    python3 -m unittest scripts/test_var_dump_analyze.py

They pin the vars.csv catalog contract (tests/harness/catalog.lua reads it by column position),
the VarBit helpers it relies on and the redaction policy, on a four-var in-memory snapshot."""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).with_name("var-dump-analyze.py")
spec = importlib.util.spec_from_file_location("var_dump_analyze", SCRIPT)
analyze = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyze)

SNAPSHOT = [
    {"domain": "VarPlayer", "id": 100, "name": "DEMO_BASE", "valueTypeName": "INTEGER", "value": 5},
    # mask 0b111000: bits 3-5 of DEMO_BASE
    {
        "domain": "VarPlayer",
        "id": 7,
        "name": "DEMO_FLAGS",
        "valueTypeName": "INTEGER",
        "value": 5,
        "isVarBit": True,
        "baseVar": "DEMO_BASE",
        "mask": 56,
    },
    {
        "domain": "VarPlayer",
        "id": 101,
        "name": "DEMO_UID",
        "valueTypeName": "PLAYER_UID",
        "value": 12345,
    },
    {"domain": "VarClient", "id": 3, "name": "DEMO_LABEL", "valueTypeName": "STRING", "value": ""},
]


def annotated(snapshot):
    """Copies of the snapshot's vars, annotated by the real step main() runs before building rows."""
    vars_ = [dict(v) for v in snapshot]
    analyze.annotate(vars_, 0)
    return vars_


class BitRange(unittest.TestCase):
    def test_contiguous_mask(self):
        self.assertEqual(analyze.bit_range(56), (3, 5))
        self.assertEqual(analyze.bit_range(1), (0, 0))

    def test_empty_mask_has_no_range(self):
        self.assertIsNone(analyze.bit_range(0))

    def test_negative_mask_is_read_as_32_bits(self):
        self.assertEqual(analyze.bit_range(-1 << 31), (31, 31))


class StateOf(unittest.TestCase):
    def test_states(self):
        by_name = {v["name"]: analyze.state_of(dict(v)) for v in SNAPSHOT}
        self.assertEqual(by_name["DEMO_BASE"], "set")
        self.assertEqual(by_name["DEMO_UID"], "redacted")
        self.assertEqual(by_name["DEMO_LABEL"], "default")

    def test_missing_value_is_unreadable(self):
        self.assertEqual(analyze.state_of({"name": "X", "error": "boom"}), "unreadable")

    def test_name_like_string_is_redacted_but_empty_one_is_not(self):
        var = {"name": "PARTY_MEMBER_NAME", "valueTypeName": "STRING", "value": "Someone"}
        self.assertEqual(analyze.state_of(var), "redacted")
        self.assertEqual(analyze.state_of({**var, "value": ""}), "default")

    def test_redacted_value_is_never_shown(self):
        var = {**SNAPSHOT[2], "_state": "redacted"}
        self.assertEqual(analyze.show_value(var), "<redacted>")


class WriteCatalog(unittest.TestCase):
    def write(self):
        """Run write_catalog on rows from catalog_rows; return (vars.csv lines, vars.csv text)."""
        vars_ = annotated(SNAPSHOT)
        tree, rows = analyze.catalog_rows(vars_)
        bases = analyze.build_basevars(vars_)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            analyze.write_catalog(out, "2026-01-01", vars_, rows, tree, bases)
            self.assertTrue((out / "families.txt").exists())
            self.assertTrue((out / "README.md").exists())
            text = (out / "vars.csv").read_text()
        return text.splitlines(), text

    def test_header_and_varbit_row(self):
        lines, _ = self.write()
        self.assertEqual(lines[0], "domain,id,name,family,group,type,base_var,bits")
        self.assertEqual(len(lines), 1 + len(SNAPSHOT))
        row = next(line for line in lines if ",DEMO_FLAGS," in line)
        self.assertEqual(row, "VarPlayer,7,DEMO_FLAGS,DEMO,DEMO,INTEGER,DEMO_BASE,3-5")

    def test_catalog_has_no_values(self):
        # SNAPSHOT carries values (5 and 12345); none may reach vars.csv.
        _, text = self.write()
        self.assertNotIn("12345", text)


class SharedSections(unittest.TestCase):
    def test_unsupported_count_comes_from_the_data(self):
        vars_ = [dict(v) for v in SNAPSHOT]
        self.assertEqual(analyze.unsupported_count(vars_), 0)
        # the real dump leaves valueTypeName off the types the API cannot convert
        for i in (0, 3):
            vars_[i].pop("valueTypeName")
            vars_[i]["valueType"] = -1
        self.assertEqual(analyze.unsupported_count(vars_), 2)

    def test_var_kind(self):
        self.assertEqual(
            [analyze.var_kind(v) for v in SNAPSHOT],
            ["VarPlayer", "VarBit", "VarPlayer", "VarClient"],
        )
        self.assertEqual(analyze.var_kind(SNAPSHOT[1]), "VarBit")

    def test_set_column_only_with_values(self):
        vars_ = annotated(SNAPSHOT)
        tree, _ = analyze.catalog_rows(vars_)
        plain, with_set = analyze.themes_table(tree, False), analyze.themes_table(tree, True)
        self.assertEqual(plain[0], "| Theme | Families | Vars |")
        self.assertEqual(with_set[0], "| Theme | Families | Vars | Set |")
        fam_plain = analyze.families_table(tree, analyze.structure_stats, False)
        fam_set = analyze.families_table(tree, analyze.node_stats, True)
        self.assertNotIn("Set", fam_plain[0])
        self.assertIn("| Set |", fam_set[0])
        # header, rule and the single DEMO family
        self.assertEqual(len(fam_set), 3)

    def test_basevar_lines_name_overlaps_only_on_request(self):
        bases = analyze.build_basevars(annotated(SNAPSHOT))
        bases[0]["overlapping"] = True
        self.assertTrue(analyze.basevar_lines(bases, True)[1].endswith(": `DEMO_BASE`."))
        self.assertTrue(
            analyze.basevar_lines(bases, False)[1].endswith("(one field read two ways).")
        )


class ReadJsonl(unittest.TestCase):
    def test_torn_and_non_object_lines_are_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "changes.jsonl"
            path.write_text('{"seq": 1}\n5\n{"seq": 2\n[1]\n{"seq": 3}\n')
            with contextlib.redirect_stderr(io.StringIO()):
                rows = list(analyze.read_jsonl(path))
        self.assertEqual(rows, [{"seq": 1}, {"seq": 3}])


class Snapshots(unittest.TestCase):
    def test_partial_files_are_never_the_newest(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            for name in (
                "snapshot-20260101-000000.jsonl",
                "snapshot-20260102-000000.jsonl.partial",
            ):
                (d / name).write_text("")
            self.assertEqual(
                [p.name for p in analyze.list_snapshots(d)], ["snapshot-20260101-000000.jsonl"]
            )

    def test_split_sessions_splits_on_equal_seq(self):
        sessions = analyze.split_sessions([{"seq": 1}, {"seq": 2}, {"seq": 2}, {"seq": 3}])
        self.assertEqual([len(s) for s in sessions], [2, 2])


if __name__ == "__main__":
    unittest.main()
