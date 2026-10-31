{
  description = "rsplugins dev environment: Lua 5.4 tooling for RS3 client plugins, plus Python for the helper scripts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Community LuaLS stubs generated from developer.runescape.com: our API reference (docs/api/)
    # and the type info behind the lua-language-server check. Pinned here rather than vendored
    # because the repo has no licence. Bump with `nix flake update api-stubs`.
    api-stubs = {
      url = "github:FriendlyDevelopment/runescape-api-stubs";
      flake = false;
    };
    # Third-party dev plugins for the beta client, copied into plugins/ by the shellHook. Pinned
    # rather than vendored: debug-plugin has no licence, and neither is ours to submit.
    # Bump with `nix flake update debug-plugin dev-kit`.
    debug-plugin = {
      url = "github:FriendlyDevelopment/debug-plugin";
      flake = false;
    };
    dev-kit = {
      url = "github:wildrabbet/dev-kit";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      api-stubs,
      debug-plugin,
      dev-kit,
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
        "x86_64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      devShells = forAllSystems (
        { pkgs, ... }:
        {
          default = pkgs.mkShell {
            name = "rsplugins";

            packages = [
              # The client runs Lua 5.4.8; nixpkgs has 5.4.7, close enough for
              # `luac -p` syntax checks and running plugin code against mocks.
              # busted runs tests/ (scripts/test-lua.sh); the harness itself reads
              # plugin.json with dkjson and times callbacks with luasystem.
              (pkgs.lua5_4.withPackages (ps: [
                ps.busted
                ps.dkjson
                ps.luasystem
              ]))
              pkgs.lua-language-server
              pkgs.stylua
              pkgs.selene
              # The Python scripts (stdlib only) and check.sh, which uses it to validate plugin.json
              # and to filter LuaLS's report.
              pkgs.python3
              # Lints and formats scripts/ (ruff.toml); check.sh gates on it.
              pkgs.ruff
              pkgs.git
              # node runs the .claude/workflows/ tests; jq is needed by check.sh, check-submission.sh
              # and the durable-state hook.
              pkgs.nodejs
              pkgs.jq
              # scripts/rsdev.py shot: capture the client window (X11 only).
              pkgs.maim
              pkgs.xprop
              pkgs.xwininfo
              pkgs.imagemagick
              # rsdev.py input (planned, docs/plans/client-driving.md): XTEST clicks and keys into the
              # client and Bolt, held off while xprintidle shows the user was just active.
              pkgs.xdotool
              pkgs.xprintidle
            ];

            shellHook = ''
              # docs/api is a gitignored symlink to the pinned stubs, so .luarc.json, editors and
              # grep all find them at a stable repo path. Only replace a symlink (or nothing):
              # never clobber a real directory someone put there.
              root=$(git rev-parse --show-toplevel 2>/dev/null)
              if [ -n "$root" ] && { [ -L "$root/docs/api" ] || [ ! -e "$root/docs/api" ]; }; then
                ln -sfn ${api-stubs} "$root/docs/api"
              fi

              # Third-party dev plugins: COPIED (not linked) into plugins/<name>, which the client's
              # dev_plugins symlink exposes; the folder name is the plugin's console name. The
              # client skips symlinked plugin folders inside dev_plugins (probe 2026-10-26: a real
              # folder was listed, a symlink to a real folder was not), so a link would be invisible.
              # .flake-source in each copy records the store path it came from: a copy is refreshed
              # only when that differs from the pinned input, and a folder without the marker is
              # someone's own work and is never touched.
              # Two shells entering at once (an editor's direnv and a terminal) must not both swap
              # the same folder: the loser's rename would nest its copy inside the winner's. A
              # mkdir lock serialises them; a shell that finds it held skips the plugin rather than
              # wait. It is released explicitly (no trap: this hook is sourced into the user's
              # shell). A lock older than 10 minutes is a killed shell's leftover and is taken over.
              sync_plugin() { # <name> <store path holding main.lua>
                lock="$root/plugins/.$1.lock"
                if ! mkdir "$lock" 2>/dev/null; then
                  if [ -n "$(find "$lock" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
                    rmdir "$lock" 2>/dev/null
                    mkdir "$lock" 2>/dev/null || { echo "another shell is refreshing $1; skipped" >&2; return 0; }
                  else
                    echo "another shell is refreshing $1; skipped" >&2
                    return 0
                  fi
                fi
                sync_plugin_locked "$@" || :
                rmdir "$lock" 2>/dev/null
                return 0
              }
              sync_plugin_locked() { # <name> <store path holding main.lua>; caller holds the lock
                dest="$root/plugins/$1"
                src=$2
                [ -f "$src/main.lua" ] || echo "warning: $1 input has no main.lua (upstream moved it?)" >&2
                if [ -d "$dest" ] && [ ! -L "$dest" ]; then
                  if [ ! -f "$dest/.flake-source" ]; then
                    echo "warning: plugins/$1 is a real directory without .flake-source; leaving it alone" >&2
                    return 0
                  fi
                  [ "$(cat "$dest/.flake-source")" = "$src" ] && return 0
                elif [ -e "$dest" ] && [ ! -L "$dest" ]; then
                  echo "warning: plugins/$1 is a file, not a directory; leaving it alone" >&2
                  return 0
                fi
                # Copy aside first so a failed copy never leaves a half-written plugin folder. The
                # marker goes in before the copy so a temp dir left by a killed shell is already
                # skipped by check.sh; it is rewritten after in case upstream ships that name.
                # Store files are read-only, so make the copy user-writable (portable to darwin cp).
                tmp=$(mktemp -d "$root/plugins/.$1.XXXXXX") &&
                  chmod 755 "$tmp" &&
                  echo "$src" > "$tmp/.flake-source" &&
                  cp -R "$src/." "$tmp" &&
                  chmod -R u+w "$tmp" &&
                  echo "$src" > "$tmp/.flake-source" ||
                  { rm -rf "$tmp"; echo "warning: could not copy $1 into plugins/" >&2; return 0; }
                # Rename the old folder aside rather than delete it first, so the window with no
                # folder is two renames wide; it is deleted only once the new one is in place.
                old="$root/plugins/.$1.old.$$"
                rm -rf "$old"
                if [ -L "$dest" ]; then
                  rm -f "$dest"
                elif [ -d "$dest" ]; then
                  mv "$dest" "$old"
                fi
                if mv "$tmp" "$dest"; then
                  rm -rf "$old"
                else
                  [ -d "$old" ] && mv "$old" "$dest"
                  rm -rf "$tmp"
                  echo "warning: could not copy $1 into plugins/" >&2
                fi
                return 0
              }
              if [ -n "$root" ]; then
                sync_plugin debug-plugin ${debug-plugin}
                sync_plugin dev-kit ${dev-kit}/dev-kit
              fi

              echo "rsplugins dev shell"
              echo "  lua / luac                    Lua $(lua -v 2>&1 | cut -d' ' -f2) (client runs 5.4.8)"
              echo "  lua-language-server           LSP for editors; docs/api/ holds the API stubs"
              echo "  stylua / selene               Lua formatter / linter"
              echo "  ruff                          Python formatter / linter (scripts/)"
              echo "  plugins and scripts           indexed in README.md (tables: Plugins, Scripts)"
              echo "  scripts/check.sh              the gate; run it before committing"
            '';
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
