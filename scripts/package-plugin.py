#!/usr/bin/env python3
"""Build a plugin's Mod.io upload: a copy with its dev opt-ins stripped, checked, then zipped.

Usage: python3 -I scripts/package-plugin.py <plugin> [--skip-lint] [--keep-http-access]

  <plugin>             a folder under plugins/
  --skip-lint          don't run scripts/check.sh on the copy (check-submission.sh always runs)
  --keep-http-access   keep httpAccess in plugin.json, for a plugin whose own feature needs it

Writes <repo>/<plugin>-<version>.zip with main.lua and plugin.json at its root, following
docs/submission.md ("Preparing the zip from this repo"). The copy is staged in
dumps/submission/plugins/<plugin>/, inside the repo so the lint configs apply, and is left there
to read.

What is stripped:
  - the plugin's dev/ link (to lib/dev);
  - in every .lua file, each span from a line `-- dev-only:begin` to a line `-- dev-only:end`
    (both included), and each line ending in `-- dev-only` or `-- dev-only: <why>`;
  - in plugin.json, httpAccess from permissions and optionalPermissions, and every url that
    points at this machine (urls.rsdev and the like), dropping a list or table left empty.

scripts/check-submission.sh then has to pass on the copy, so a dev line nobody marked stops the
build rather than shipping. A plugin that needs dev/ to work (the dev bridge, var-dump) can't be
packaged.
"""

import argparse
import json
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = Path(__file__).resolve().parent

BEGIN = "-- dev-only:begin"
END = "-- dev-only:end"
# A code line marked on its own: `if tee then tee.shutdown() end -- dev-only: why`.
TRAILING = re.compile(r"\s--\s*dev-only(:.*)?$")
# The same hosts as check-submission.sh: loopback, localhost and 0.0.0.0 as the whole host.
LOOPBACK = re.compile(
    r"^[a-zA-Z][a-zA-Z0-9+.-]*://([^/@]*@)?"
    r"(127(\.[0-9]+)*|localhost|\[::1\]|0\.0\.0\.0)\.?([:/?#]|$)",
    re.IGNORECASE,
)
# Zip entries get one fixed time, so the same tree always zips to the same bytes.
ZIP_TIME = (1980, 1, 1, 0, 0, 0)


class PackageError(Exception):
    pass


def strip_dev_lua(text, name):
    """Return `text` without its dev-only spans and lines. `name` is for error messages.

    A blank line left beside another blank line where a span was cut is dropped too, so the
    copy stays stylua-clean."""
    out = []
    open_at = None
    cut = False
    for number, line in enumerate(text.splitlines(keepends=True), start=1):
        marker = line.strip()
        if marker == BEGIN:
            if open_at is not None:
                raise PackageError(f"{name}:{number}: {BEGIN} inside the span from line {open_at}")
            open_at = number
            continue
        if marker == END:
            if open_at is None:
                raise PackageError(f"{name}:{number}: {END} without a {BEGIN}")
            open_at = None
            cut = True
            continue
        if open_at is not None:
            continue
        if TRAILING.search(line.rstrip("\r\n")):
            cut = True
            continue
        if cut and not line.strip() and (not out or not out[-1].strip()):
            continue
        cut = False
        out.append(line)
    if open_at is not None:
        raise PackageError(f"{name}:{open_at}: {BEGIN} is never closed")
    return "".join(out)


def strip_dev_manifest(manifest, keep_http_access=False):
    """Return a copy of plugin.json's table without httpAccess and urls to this machine."""
    out = dict(manifest)
    if not keep_http_access:
        for key in ("permissions", "optionalPermissions"):
            if key in out:
                out[key] = [p for p in out[key] if p != "httpAccess"]
                if not out[key]:
                    del out[key]
    if "urls" in out:
        out["urls"] = {
            k: v for k, v in out["urls"].items() if k != "rsdev" and not LOOPBACK.match(str(v))
        }
        if not out["urls"]:
            del out["urls"]
    return out


def stage(src, dest, keep_http_access):
    """Copy the plugin at `src` to `dest` without dev/, then strip the copy."""
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(src, dest, symlinks=True, ignore=lambda d, _: ["dev"] if Path(d) == src else [])
    for path in sorted(dest.rglob("*")):
        rel = path.relative_to(dest)
        if path.is_symlink():
            raise PackageError(f"{src.name}/{rel} is a link; only dev/ may be one")
        if path.suffix == ".lua":
            path.write_text(strip_dev_lua(path.read_text(), f"{src.name}/{rel}"))
    manifest_path = dest / "plugin.json"
    manifest = strip_dev_manifest(json.loads(manifest_path.read_text()), keep_http_access)
    manifest_path.write_text(json.dumps(manifest, indent=4) + "\n")
    return manifest


def write_zip(folder, zip_path):
    """Zip `folder`'s contents (not the folder itself), so main.lua sits at the archive root."""
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(p for p in folder.rglob("*") if p.is_file()):
            info = zipfile.ZipInfo(path.relative_to(folder).as_posix(), ZIP_TIME)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, path.read_bytes())


def submission_clean(plugin, staging, keep_http_access):
    """Run check-submission.sh on the staged copy; True when it found no dev piece.

    That script always flags httpAccess, so with --keep-http-access those findings alone pass."""
    check = [str(SCRIPTS / "check-submission.sh"), plugin, "--root", str(staging)]
    print(f"$ {' '.join(check)}", flush=True)
    result = subprocess.run(check, capture_output=True, text=True)
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    if result.returncode == 0:
        return True
    if result.returncode != 1 or not keep_http_access:
        return False
    pieces = [line for line in result.stdout.splitlines() if line.startswith("dev piece: ")]
    if pieces and all(line.startswith("dev piece: httpAccess in ") for line in pieces):
        print("Kept httpAccess: the Mod.io Permissions section must say what it is for.")
        return True
    return False


def main(argv=None, root=ROOT):
    parser = argparse.ArgumentParser(description="Build a plugin's Mod.io upload zip.")
    parser.add_argument("plugin")
    parser.add_argument("--skip-lint", action="store_true")
    parser.add_argument("--keep-http-access", action="store_true")
    args = parser.parse_args(argv)

    src = root / "plugins" / args.plugin
    if not (src / "main.lua").is_file() or not (src / "plugin.json").is_file():
        print(f"Unknown plugin: {src} has no main.lua and plugin.json", file=sys.stderr)
        return 2
    staging = root / "dumps" / "submission"
    dest = staging / "plugins" / args.plugin
    try:
        manifest = stage(src, dest, args.keep_http_access)
    except (PackageError, json.JSONDecodeError) as err:
        print(f"Can't package {args.plugin}: {err}", file=sys.stderr)
        return 1

    if not submission_clean(args.plugin, staging, args.keep_http_access):
        print(f"Not packaged: the copy in {dest} failed the check above.", file=sys.stderr)
        return 1
    if not args.skip_lint:
        lint = [str(SCRIPTS / "check.sh"), str(dest.relative_to(root))]
        print(f"$ {' '.join(lint)}", flush=True)
        if subprocess.run(lint, cwd=root).returncode != 0:
            print(f"Not packaged: the copy in {dest} failed the check above.", file=sys.stderr)
            return 1

    version = str(manifest.get("version", "0"))
    zip_path = root / f"{args.plugin}-{version}.zip"
    write_zip(dest, zip_path)
    print(f"Wrote {zip_path}")
    if manifest.get("contactEmailAddress") == "you@example.com":
        print("Warning: plugin.json's contactEmailAddress is still the placeholder.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
