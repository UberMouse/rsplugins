#!/usr/bin/env bash
# The build gate for plugin code: every change must pass this before it is committed. It lints
# plugins/, lib/ and tests/ and runs the plugin tests; behaviour the harness doesn't model still
# has to be checked in the beta client (`prl <plugin>`).
#
#   1. luac -p        Lua 5.4 syntax (the client runs 5.4.8, nixpkgs has 5.4.7)
#   2. plugin.json    each manifest parses as JSON (a broken one silently stops the plugin loading)
#   3. selene         lint (unused/shadowed/accidental globals...), per selene.toml and rs.yml;
#                     tests/ uses tests/selene.toml (adds the luassert assertions)
#   4. stylua --check formatting, per stylua.toml
#   5. LuaLS          type check: plugin code against the API stubs in docs/api/ (.luarc.json):
#                     undefined globals and members, wrong argument types, unchecked nil;
#                     tests/ against busted/luassert instead (tests/.luarc.json), since spec and
#                     harness code run outside the plugin sandbox
#   6. tests          scripts/test-lua.sh: every tests/**/*_spec.lua under busted (always the
#                     whole suite, whatever paths were given)
#
# Usage: scripts/check-lua.sh [path ...]
#   Paths default to plugins/, lib/ and tests/ (those that exist). Exit 0 = all checks passed;
#   non-zero = at least one failed, with each failing check's output above the summary.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in luac selene stylua lua-language-server python3 busted; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not on PATH: run inside the dev shell (direnv, or nix develop)" >&2
        exit 2
    fi
done

paths=("$@")
if [[ ${#paths[@]} -eq 0 ]]; then
    for dir in plugins lib tests; do
        [[ -d $dir ]] && paths+=("$dir")
    done
fi

mapfile -t lua_files < <(find "${paths[@]}" -name '*.lua' -type f | sort)
mapfile -t manifests < <(find "${paths[@]}" -name plugin.json -type f | sort)
# tests/ has its own selene and LuaLS config; everything else is plugin-side code.
test_files=()
plugin_files=()
for f in "${lua_files[@]}"; do
    if [[ $f == tests/* || $f == ./tests/* ]]; then test_files+=("$f"); else plugin_files+=("$f"); fi
done
failed=()

for f in "${lua_files[@]}"; do
    luac -p "$f" || failed+=("luac $f")
done
# luac writes luac.out even with -p on some builds; never leave it in the tree.
rm -f luac.out

for m in "${manifests[@]}"; do
    python3 -m json.tool "$m" >/dev/null || failed+=("json $m")
done

# LuaLS checks the whole workspace, so report only diagnostics in the files asked about.
# Usage: luals <label> <config file> <file...>
luals() {
    local label=$1 config=$2
    shift 2
    local out
    out=$(mktemp -d)
    if ! lua-language-server --check . --configpath "$config" --checklevel Warning \
        --check_format json --check_out_path "$out/check.json" >/dev/null 2>&1; then
        python3 - "$out/check.json" "$@" <<'PY' || failed+=("$label")
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
}

if [[ ${#lua_files[@]} -gt 0 ]]; then
    if [[ ${#plugin_files[@]} -gt 0 ]]; then
        selene --display-style quiet "${plugin_files[@]}" || failed+=("selene")
    fi
    if [[ ${#test_files[@]} -gt 0 ]]; then
        selene --config tests/selene.toml --display-style quiet "${test_files[@]}" ||
            failed+=("selene (tests)")
    fi
    stylua --check "${lua_files[@]}" || failed+=("stylua (run: stylua ${paths[*]})")

    if [[ ! -e docs/api/types.lua ]]; then
        echo "docs/api/ is missing: enter the dev shell (direnv, or nix develop) to link the API stubs" >&2
        failed+=("luals (no docs/api)")
    else
        [[ ${#plugin_files[@]} -gt 0 ]] && luals "luals" .luarc.json "${plugin_files[@]}"
        [[ ${#test_files[@]} -gt 0 ]] && luals "luals (tests)" tests/.luarc.json "${test_files[@]}"
    fi
fi

# Only the summary on success; busted's full report on failure.
if test_out=$(scripts/test-lua.sh 2>&1); then
    test_summary=$(grep -E '^[0-9]+ successes' <<<"$test_out")
else
    echo "$test_out"
    failed+=("tests (run: scripts/test-lua.sh)")
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'check-lua: FAILED (%d): %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
printf 'check-lua: ok (%d lua files, %d manifests; tests: %s)\n' \
    "${#lua_files[@]}" "${#manifests[@]}" "$test_summary"
