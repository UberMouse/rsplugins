#!/usr/bin/env bash
# Point the beta client's dev_plugins folder at this repo's plugins/ directory,
# so every plugin in plugins/ is visible to the client (`prf` then `plist`).
#
# Usage: scripts/link-dev-plugins.sh [beta root]
#   beta root defaults to Bolt's location; override for other launchers.
#   Run it from the main checkout, not a worktree, so the link survives worktree cleanup.
set -euo pipefail

repo_plugins="$(cd "$(dirname "${BASH_SOURCE[0]}")/../plugins" && pwd)"
beta_root="${1:-$HOME/.local/share/bolt-launcher/Jagex/RuneScape-BETA}"
link="$beta_root/dev_plugins"

if [[ ! -d "$beta_root" ]]; then
    echo "Beta root not found: $beta_root (log into the beta once first, or pass the path)" >&2
    exit 1
fi

if [[ -L "$link" ]]; then
    if [[ "$(readlink "$link")" == "$repo_plugins" ]]; then
        echo "Already linked: $link -> $repo_plugins"
        exit 0
    fi
    echo "$link is a symlink to $(readlink "$link"); remove it first if you want to relink" >&2
    exit 1
fi

if [[ -d "$link" ]]; then
    # The client may have created an empty dev_plugins; never clobber one with content.
    rmdir "$link" 2>/dev/null || { echo "$link exists and is not empty; move its contents first" >&2; exit 1; }
fi

ln -s "$repo_plugins" "$link"
echo "Linked: $link -> $repo_plugins"
