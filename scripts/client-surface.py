#!/usr/bin/env python3
"""Snapshot the beta client's API surface through the dev bridge, as a test fixture.

Runs plugins/dev-bridge/probes/client-surface.lua with `rsdev.py eval`: defines it, arms its
event probes, waits for payloads, collects, and writes tests/fixtures/client-surface.json. The
snapshot holds names, type() and enum numbers only (the probe's header says what it reads).
tests/harness/client_surface_spec.lua checks the harness's mocks against it. Re-run it after a
client update. Needs the bridge connected (`scripts/rsdev.py status`); it ends with
`eval --reset`, which clears every eval probe and the scratch env.

    scripts/client-surface.py [--wait 20] [--out tests/fixtures/client-surface.json]
"""

import argparse
import datetime
import json
import pathlib
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parent.parent
PROBE = REPO / "plugins/dev-bridge/probes/client-surface.lua"
FIXTURE = REPO / "tests/fixtures/client-surface.json"
RSDEV = REPO / "scripts/rsdev.py"
SCHEMA = 1


def rsdev(*args):
    """Run `rsdev.py <args>`, exiting with its stderr if it fails; returns its stdout."""
    done = subprocess.run([sys.executable, str(RSDEV), *args], capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(f"rsdev.py {args[0]} failed (exit {done.returncode}): {done.stderr.strip()}")
    return done.stdout


def eval_values(*args):
    """The values an eval returned, refusing a result the bridge cut to fit its caps."""
    result = json.loads(rsdev("eval", *args))
    if result.get("truncated"):
        sys.exit("the bridge truncated the result: split the probe's output further")
    return result["values"]


def snapshot(wait):
    """Define, arm, wait and collect; the merged snapshot."""
    eval_values("--file", str(PROBE))
    try:
        eval_values("SURFACE.arm()")
        time.sleep(wait)
        base, enums, rest = eval_values("SURFACE.collect()")
    finally:
        rsdev("eval", "--reset")
    return {
        "schema": SCHEMA,
        "captured": datetime.date.today().isoformat(),
        **base,
        "enums": enums,
        **rest,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--wait", type=float, default=20.0, help="seconds to collect payloads")
    parser.add_argument("--out", type=pathlib.Path, default=FIXTURE)
    args = parser.parse_args()
    snap = snapshot(args.wait)
    args.out.write_text(json.dumps(snap, indent=1, sort_keys=True) + "\n")
    print(
        f"wrote {args.out}: {len(snap['globals'])} globals, {len(snap['namespaces'])} namespaces,"
        f" {len(snap['enums'])} enums, {len(snap['types'])} types,"
        f" payloads of {', '.join(sorted(snap['events'])) or 'no events'}"
    )


if __name__ == "__main__":
    main()
