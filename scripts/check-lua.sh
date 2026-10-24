#!/usr/bin/env bash
# The build gate for plugin code: every change must pass this before it is committed. There is no
# typechecker or test runner for client plugins, so this is the whole automated signal; behaviour
# still has to be checked in the beta client (`prl <plugin>`).
#
#   1. luac -p        Lua 5.4 syntax (the client runs 5.4.8, nixpkgs has 5.4.7)
#   2. plugin.json    each manifest parses as JSON (a broken one silently stops the plugin loading)
#   3. selene         lint, with rs.yml declaring the Client Plugin API globals
#   4. stylua --check formatting, per stylua.toml
#
# Usage: scripts/check-lua.sh [path ...]
#   Paths default to plugins/. Exit 0 = all checks passed; non-zero = at least one failed, with
#   each failing check's output above the summary.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in luac selene stylua python3; do
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
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'check-lua: FAILED (%d): %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
printf 'check-lua: ok (%d lua files, %d manifests)\n' "${#lua_files[@]}" "${#manifests[@]}"
