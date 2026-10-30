#!/usr/bin/env bash
# The build gate: every change must pass this before it is committed. It gates Lua (plugins/,
# lib/, tests/), Python scripts, the JS workflow tests and the shell hook selftests; behaviour the
# mock harness doesn't model still has to be checked in the beta client (`prl <plugin>`).
# This header is the one list of steps; docs point here rather than copying it.
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
#   7. python tests   every scripts/test_*.py, found by unittest discovery (always)
#   8. js tests       each .claude/workflows/*.test.js under node (always)
#   9. hook selftests each .claude/hooks/*.selftest.sh (always)
#  10. submission    scripts/check-submission.selftest.sh: the submission check's cases (always)
#  11. mod checks     claude plugin validate + test on each Claude Code mod under .claude/skills/
#                     (always; tsc needs hand-copied engine types, see .claude/skills/rsp-ops/README.md)
#  12. ruff           ruff check + ruff format --check on scripts/, per ruff.toml (always)
#
# Usage: scripts/check.sh [path ...]
#   Paths default to plugins/, lib/ and tests/ (those that exist) and only narrow steps 1-5. Any
#   folder holding a .flake-source marker (the flake shellHook's copies of third-party plugins, not
#   our code) is skipped. Exit 0 = all checks passed;
#   non-zero = at least one failed, with each failing check's output above the summary.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

for tool in luac selene stylua lua-language-server python3 ruff busted node jq; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not on PATH: run inside the dev shell (direnv, or nix develop)." >&2
        echo "A shell started before flake.nix changed needs \`direnv reload\`, or run \`direnv exec . scripts/check.sh\`." >&2
        exit 2
    fi
done

paths=("$@")
if [[ ${#paths[@]} -eq 0 ]]; then
    for dir in plugins lib tests; do
        [[ -d $dir ]] && paths+=("$dir")
    done
fi

# Prune folders carrying the marker so neither the checks nor the tests see them.
prune=()
while IFS= read -r dir; do
    prune+=(-path "$dir" -prune -o)
done < <(find "${paths[@]}" -name .flake-source -type f -exec dirname {} \;)
mapfile -t lua_files < <(find "${paths[@]}" "${prune[@]}" -name '*.lua' -type f -print | sort)
mapfile -t manifests < <(find "${paths[@]}" "${prune[@]}" -name plugin.json -type f -print | sort)
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

# Quiet on success; on failure print the captured output and record the label (also when the
# command cannot start, since its error text is captured too).
# Usage: run_step <label> <cmd...>
run_step() {
    local label=$1 out
    shift
    if ! out=$("$@" 2>&1); then
        echo "$out"
        failed+=("$label")
    fi
}

# Discovery means a new scripts/test_*.py is gated without editing this file.
PYTHONDONTWRITEBYTECODE=1 run_step \
    "python tests (run: python3 -m unittest discover -s scripts -p 'test_*.py')" \
    python3 -m unittest discover -s scripts -p 'test_*.py'

# The JS tests exit non-zero on any failure; one of them reads the repo's Lua history.
for t in .claude/workflows/*.test.js; do
    run_step "js test $t" node "$t"
done

for t in .claude/hooks/*.selftest.sh; do
    run_step "hook selftest $t" "$t"
done

run_step "submission selftest" scripts/check-submission.selftest.sh

# A mod is a skills folder with a plugin manifest; the others are plain skills.
for mod in .claude/skills/*/.claude-plugin/plugin.json; do
    [[ -f $mod ]] || continue
    dir=${mod%/.claude-plugin/plugin.json}
    run_step "mod validate $dir" claude plugin validate "$dir"
    run_step "mod test $dir" claude plugin test "$dir"
done

# Format is checked as well as lint so the style cannot drift back.
run_step "ruff check (fix: ruff check --fix scripts)" ruff check scripts
run_step "ruff format (fix: ruff format scripts)" ruff format --check scripts

if [[ ${#failed[@]} -gt 0 ]]; then
    printf 'check: FAILED (%d): %s\n' "${#failed[@]}" "${failed[*]}" >&2
    exit 1
fi
printf 'check: ok (%d lua files, %d manifests; tests: %s)\n' \
    "${#lua_files[@]}" "${#manifests[@]}" "$test_summary"
