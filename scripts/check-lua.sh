#!/usr/bin/env bash
# Shim: the gate was renamed to scripts/check.sh. This exists only for sessions started before
# the rename and can be deleted.
exec "$(dirname "${BASH_SOURCE[0]}")/check.sh" "$@"
