#!/usr/bin/env bash
# The build gate for plugin code: every change must pass this before it is committed. There is no
# test runner for client plugins, so this is the whole automated signal; behaviour still has to be
# checked in the beta client (`prl <plugin>`).
#
#   1. luac -p        Lua 5.4 syntax (the client runs 5.4.8, nixpkgs has 5.4.7)
#   2. plugin.json    each manifest parses as JSON (a broken one silently stops the plugin loading)
#   3. selene         lint (unused/shadowed/accidental globals...), per selene.toml and rs.yml
#   4. stylua --check formatting, per stylua.toml
#   5. LuaLS          type check against the API stubs in docs/api/ (.luarc.json): undefined
#                     globals and members, wrong argument types, unchecked nil
#
# Usage: scripts/check-lua.sh [path ...]
#   Paths default to plugins/. Exit 0 = all checks passed; non-zero = at least one failed, with
#   each failing check's output above the summary.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in luac selene stylua lua-language-server python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not on PATH: run inside the dev shell (direnv, or nix develop)" >&2
        exit 2
    fi
done

paths=("$@")
[[ ${#paths[@]} -gt 0 ]] || paths=(plugins)

mapfile -t lua_files < <(find "${paths[@]}" -name '*.lua' -type f | sort)
mapfile -t manifests < <(find "${paths[@]}" -name plugin.json -type f | sort)
failed=()

for f in "${lua_files[@]}"; do
    luac -p "$f" || failed+=("luac $f")
done
# luac writes luac.out even with -p on some builds; never leave it in the tree.
rm -f luac.out

for m in "${manifests[@]}"; do
    python3 -m json.tool "$m" >/dev/null || failed+=("json $m")
done

if [[ ${#lua_files[@]} -gt 0 ]]; then
    selene --display-style quiet "${lua_files[@]}" || failed+=("selene")
    stylua --check "${lua_files[@]}" || failed+=("stylua (run: stylua ${paths[*]})")

    if [[ ! -e docs/api/types.lua ]]; then
        echo "docs/api/ is missing: enter the dev shell (direnv, or nix develop) to link the API stubs" >&2
        failed+=("luals (no docs/api)")
    else
        # LuaLS checks the whole workspace, so report only diagnostics in the files asked about.
        out=$(mktemp -d)
        if ! lua-language-server --check . --checklevel Warning --check_format json \
            --check_out_path "$out/check.json" >/dev/null 2>&1; then
            python3 - "$out/check.json" "${lua_files[@]}" <<'PY' || failed+=("luals")
import json, os, sys
from urllib.parse import unquote, urlparse

report, wanted = sys.argv[1], {os.path.abspath(f) for f in sys.argv[2:]}
if not os.path.exists(report):
    sys.exit("lua-language-server failed without writing a report")
problems = 0
for uri, diags in sorted(json.load(open(report)).items()):
    path = os.path.abspath(unquote(urlparse(uri).path))
    if path not in wanted:
        continue
    for d in diags:
        start = d["range"]["start"]
        print(f"{os.path.relpath(path)}:{start['line'] + 1}:{start['character'] + 1}: "
              f"{d['message']} ({d['code']})")
        problems += 1
sys.exit(1 if problems else 0)
PY
        fi
        rm -rf "$out"
    fi
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'check-lua: FAILED (%d): %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
printf 'check-lua: ok (%d lua files, %d manifests)\n' "${#lua_files[@]}" "${#manifests[@]}"
