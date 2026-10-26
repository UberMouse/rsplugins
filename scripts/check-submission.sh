#!/usr/bin/env bash
# Fails while a plugin still carries the dev-only log tee (lib/dev/tee.lua): the dev/ link, the
# require and tee.install/tee.shutdown calls, the httpAccess permission and the urls.rsdev key.
# Run it on a copy of the plugin prepared for upload, not on the dev tree, where it is expected
# to fail.
#
# Usage: scripts/check-submission.sh <plugin> [--root <dir>]
#   <dir> is a folder holding plugins/<plugin>/ (default: this repo).
#   Exit 0 = clean, 1 = dev pieces found, 2 = usage error or plugin.json is not valid JSON.
set -euo pipefail

usage() {
    echo "Usage: scripts/check-submission.sh <plugin> [--root <dir>]" >&2
    exit 2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin=""
while (($#)); do
    case "$1" in
        --root)
            [[ $# -ge 2 ]] || usage
            root="$2"
            shift 2
            ;;
        -*) usage ;;
        *)
            [[ -z "$plugin" ]] || usage
            plugin="$1"
            shift
            ;;
    esac
done
[[ -n "$plugin" ]] || usage

dir="$root/plugins/$plugin"
if [[ ! -d "$dir" ]]; then
    echo "Unknown plugin: $dir is not a folder" >&2
    exit 2
fi

found=0
report() {
    echo "dev piece: $1"
    found=1
}

if [[ -e "$dir/dev" || -L "$dir/dev" ]]; then
    report "dev entry at plugins/$plugin/dev"
fi

lua_pattern="require *\(? *([\"']|\[=*\[)dev[./]|tee\.(install|shutdown)"
while IFS= read -r hit; do
    report "${hit#"$root"/}"
done < <(grep -rnE --include='*.lua' "$lua_pattern" "$dir" || true)

manifest="$dir/plugin.json"
if [[ -f "$manifest" ]]; then
    jq empty "$manifest" 2>/dev/null || {
        echo "plugins/$plugin/plugin.json is not valid JSON" >&2
        exit 2
    }
    for key in permissions optionalPermissions; do
        has_http="$(jq -r --arg k "$key" '(.[$k] // []) | index("httpAccess") != null' "$manifest")"
        if [[ "$has_http" == true ]]; then
            report "httpAccess in $key of plugins/$plugin/plugin.json"
        fi
    done
    if [[ "$(jq -r '(.urls // {}) | has("rsdev")' "$manifest")" == true ]]; then
        report "urls.rsdev in plugins/$plugin/plugin.json"
    fi
fi

if ((found)); then
    echo "Strip these first: see plugins/$plugin/README.md, \"Before submitting\"." >&2
    exit 1
fi
echo "ok: plugins/$plugin has no dev pieces"
