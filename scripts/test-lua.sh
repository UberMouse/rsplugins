#!/usr/bin/env bash
# Run the plugin tests: every tests/**/*_spec.lua, under busted, against the mock API in
# tests/harness/ (see docs/testing.md). Exit 0 = all passed; non-zero = at least one failed.
#
# Usage: scripts/test-lua.sh [busted args...]
#   e.g. scripts/test-lua.sh tests/harness/events_spec.lua, or --filter='reload'
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

if ! command -v busted >/dev/null; then
    echo "busted not on PATH: run inside the dev shell (direnv, or nix develop)" >&2
    exit 2
fi
if [[ ! -e docs/api/types.lua ]]; then
    echo "docs/api/ is missing: enter the dev shell (direnv, or nix develop) to link the API stubs" >&2
    exit 2
fi

# .busted (repo root) sets the spec root, the _spec.lua pattern and the module path.
exec busted "$@"
