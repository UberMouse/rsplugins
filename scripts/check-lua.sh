#!/usr/bin/env bash
# Forwards to scripts/check.sh, the gate's current name; delete once nothing still invokes
# check-lua.sh.
exec "$(dirname "${BASH_SOURCE[0]}")/check.sh" "$@"
