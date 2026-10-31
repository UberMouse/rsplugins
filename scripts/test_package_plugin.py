"""Tests for scripts/package-plugin.py, run by scripts/check.sh:

    python3 -m unittest scripts/test_package_plugin.py

The end-to-end cases run the real check-submission.sh on a throwaway repo, but never check.sh
(--skip-lint), which runs this file."""

import contextlib
import importlib.util
import io
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

SCRIPT = Path(__file__).with_name("package-plugin.py")
spec = importlib.util.spec_from_file_location("package_plugin", SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)

MAIN = """-- Demo plugin.
--
-- dev-only:begin
-- Dev checkout only: the tee.
--
-- dev-only:end
-- What it does.

-- dev-only:begin
local tee = require("dev/tee")
if tee then tee.install(_ENV, "demo") end
-- dev-only:end

local x = 1

function PluginShutdown()
    print(x)
    if tee then tee.shutdown() end -- dev-only: the tee's own subscription
end
"""

STRIPPED = """-- Demo plugin.
--
-- What it does.

local x = 1

function PluginShutdown()
    print(x)
end
"""


class StripDevLua(unittest.TestCase):
    def test_drops_spans_marked_lines_and_the_blank_line_a_span_leaves(self):
        self.assertEqual(package.strip_dev_lua(MAIN, "main.lua"), STRIPPED)

    def test_keeps_unmarked_text_unchanged(self):
        self.assertEqual(package.strip_dev_lua(STRIPPED, "main.lua"), STRIPPED)

    def test_keeps_blank_lines_away_from_a_cut(self):
        text = "local a = 1\n\n\nlocal b = 2\n"
        self.assertEqual(package.strip_dev_lua(text, "main.lua"), text)

    def test_bare_trailing_marker(self):
        text = "local a = 1\nif tee then tee.shutdown() end -- dev-only\nlocal b = 2\n"
        self.assertEqual(package.strip_dev_lua(text, "m"), "local a = 1\nlocal b = 2\n")

    def test_prose_naming_the_marker_stays(self):
        text = "-- Lines marked dev-only are stripped by package-plugin.py.\n"
        self.assertEqual(package.strip_dev_lua(text, "m"), text)

    def test_unbalanced_markers_fail_with_the_line(self):
        cases = {
            "-- dev-only:begin\nx()\n": "m:1: -- dev-only:begin is never closed",
            "x()\n-- dev-only:end\n": "m:2: -- dev-only:end without a -- dev-only:begin",
            "-- dev-only:begin\n-- dev-only:begin\n": "m:2: -- dev-only:begin inside",
        }
        for text, message in cases.items():
            with self.subTest(text=text):
                with self.assertRaises(package.PackageError) as caught:
                    package.strip_dev_lua(text, "m")
                self.assertTrue(str(caught.exception).startswith(message), caught.exception)


class StripDevManifest(unittest.TestCase):
    def test_drops_http_access_and_local_urls_and_the_emptied_keys(self):
        manifest = {
            "name": "Demo",
            "optionalPermissions": ["httpAccess"],
            "urls": {"rsdev": "http://example.com", "sink": "http://LOCALHOST:8765/x"},
        }
        self.assertEqual(package.strip_dev_manifest(manifest), {"name": "Demo"})

    def test_keeps_other_permissions_and_urls(self):
        manifest = {
            "permissions": ["chatAccess", "httpAccess"],
            "urls": {"wiki": "https://runescape.wiki", "near": "http://127.0.0.1.example.com"},
        }
        self.assertEqual(
            package.strip_dev_manifest(manifest),
            {"permissions": ["chatAccess"], "urls": manifest["urls"]},
        )

    def test_keep_http_access(self):
        manifest = {"optionalPermissions": ["httpAccess"]}
        self.assertEqual(package.strip_dev_manifest(manifest, keep_http_access=True), manifest)


class Main(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        (self.root / "lib" / "dev").mkdir(parents=True)
        self.plugin = self.root / "plugins" / "demo"
        (self.plugin / "core").mkdir(parents=True)
        (self.plugin / "dev").symlink_to("../../lib/dev")
        (self.plugin / "main.lua").write_text(MAIN)
        (self.plugin / "core" / "x.lua").write_text("return 1\n")
        (self.plugin / "plugin.json").write_text(
            json.dumps(
                {
                    "name": "Demo",
                    "version": "1.2.0",
                    "contactEmailAddress": "you@example.com",
                    "optionalPermissions": ["httpAccess"],
                    "urls": {"rsdev": "http://127.0.0.1:8766"},
                }
            )
        )

    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = package.main([*argv, "--skip-lint"], root=self.root)
        return code, out.getvalue(), err.getvalue()

    def test_zips_the_stripped_copy_with_main_lua_at_the_root(self):
        code, out, err = self.run_main("demo")
        self.assertEqual(code, 0, out + err)
        self.assertIn("contactEmailAddress is still the placeholder", out)
        with zipfile.ZipFile(self.root / "demo-1.2.0.zip") as zf:
            self.assertEqual(zf.namelist(), ["core/x.lua", "main.lua", "plugin.json"])
            self.assertEqual(zf.read("main.lua").decode(), STRIPPED)
            self.assertEqual(
                json.loads(zf.read("plugin.json")),
                {"name": "Demo", "version": "1.2.0", "contactEmailAddress": "you@example.com"},
            )
        # The dev tree itself is untouched.
        self.assertEqual((self.plugin / "main.lua").read_text(), MAIN)

    def test_an_unmarked_dev_line_stops_the_build(self):
        (self.plugin / "core" / "x.lua").write_text('local t = require("dev/tee")\nreturn t\n')
        code, out, err = self.run_main("demo")
        self.assertEqual(code, 1)
        self.assertIn("dev piece: plugins/demo/core/x.lua:1:", out)
        self.assertFalse((self.root / "demo-1.2.0.zip").exists())

    def test_keep_http_access_passes_on_that_finding_alone(self):
        code, out, err = self.run_main("demo", "--keep-http-access")
        self.assertEqual(code, 0, out + err)
        self.assertIn("Kept httpAccess", out)
        with zipfile.ZipFile(self.root / "demo-1.2.0.zip") as zf:
            manifest = json.loads(zf.read("plugin.json"))
        self.assertEqual(manifest["optionalPermissions"], ["httpAccess"])

    def test_another_link_in_the_plugin_stops_the_build(self):
        (self.plugin / "core" / "lib").symlink_to("../../../lib")
        code, out, err = self.run_main("demo")
        self.assertEqual(code, 1)
        self.assertIn("demo/core/lib is a link", err)

    def test_unknown_plugin(self):
        code, out, err = self.run_main("nope")
        self.assertEqual(code, 2)
        self.assertIn("Unknown plugin", err)


if __name__ == "__main__":
    unittest.main()
