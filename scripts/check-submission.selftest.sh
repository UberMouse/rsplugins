#!/usr/bin/env bash
# Table test for scripts/check-submission.sh, run by scripts/check.sh: each case builds a plugin
# folder in a fresh temp dir and checks the script's exit code (0 clean, 1 dev pieces found).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
failed=0

# Usage: run_case <name> <expected exit code> <plugin.json text> [dev-link]
run_case() {
    local name=$1 want=$2 manifest=$3 link=${4:-}
    local root="$tmp/$name"
    mkdir -p "$root/plugins/p"
    printf '%s\n' "$manifest" >"$root/plugins/p/plugin.json"
    echo 'print("hi")' >"$root/plugins/p/main.lua"
    [[ -z "$link" ]] || ln -s ../../lib/dev "$root/plugins/p/dev"
    "$here/check-submission.sh" p --root "$root" >/dev/null 2>&1
    local got=$?
    if ((got != want)); then
        echo "check-submission case '$name': exit $got, wanted $want" >&2
        failed=1
    fi
}

run_case clean 0 '{"name":"P","urls":{"api":"https://example.com"}}'
run_case no-urls 0 '{"name":"P"}'
run_case lookalike-host 0 '{"name":"P","urls":{"api":"http://127.0.0.1.example.com"}}'
run_case loopback-ip 1 '{"name":"P","urls":{"api":"http://127.0.0.1:9000"}}'
run_case loopback-name 1 '{"name":"P","urls":{"api":"http://localhost:9000/x"}}'
run_case loopback-short-127 1 '{"name":"P","urls":{"api":"http://127.1/x"}}'
run_case loopback-other-127 1 '{"name":"P","urls":{"api":"http://127.0.0.2:80"}}'
run_case loopback-ipv6 1 '{"name":"P","urls":{"api":"http://[::1]:9000"}}'
run_case loopback-any-addr 1 '{"name":"P","urls":{"api":"http://0.0.0.0:9000"}}'
run_case loopback-dotted-name 1 '{"name":"P","urls":{"api":"http://localhost./x"}}'
run_case loopback-dotted-ip 1 '{"name":"P","urls":{"api":"http://127.0.0.1.:9000"}}'
run_case loopback-upper 1 '{"name":"P","urls":{"api":"HTTP://LOCALHOST"}}'
run_case rsdev-key 1 '{"name":"P","urls":{"rsdev":"https://example.com"}}'
run_case http-access 1 '{"name":"P","optionalPermissions":["httpAccess"]}'
run_case dev-symlink 1 '{"name":"P"}' link

exit "$failed"
