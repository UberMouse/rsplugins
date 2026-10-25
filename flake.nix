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
              # scripts/var-dump-receiver.py (stdlib only).
              pkgs.python3
              pkgs.git
              # Tests for the .claude/workflows/ review workflow; jq for the durable-state hook.
              pkgs.nodejs
              pkgs.jq
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
              sync_plugin() { # <name> <store path holding main.lua>
                dest="$root/plugins/$1"
                src=$2
                [ -f "$src/main.lua" ] || echo "warning: $1 input has no main.lua (upstream moved it?)" >&2
                if [ -d "$dest" ] && [ ! -L "$dest" ]; then
                  if [ ! -f "$dest/.flake-source" ]; then
                    echo "warning: plugins/$1 is a real directory without .flake-source; leaving it alone" >&2
                    return
                  fi
                  [ "$(cat "$dest/.flake-source")" = "$src" ] && return
                fi
                # Copy aside first so a failed copy never leaves a half-written plugin folder.
                # Store files are read-only, so make the copy user-writable (portable to darwin cp).
                tmp=$(mktemp -d "$root/plugins/.$1.XXXXXX") &&
                  chmod 755 "$tmp" &&
                  cp -R "$src/." "$tmp" &&
                  chmod -R u+w "$tmp" &&
                  echo "$src" > "$tmp/.flake-source" &&
                  rm -rf "$dest" &&
                  mv "$tmp" "$dest" ||
                  { rm -rf "$tmp"; echo "warning: could not copy $1 into plugins/" >&2; }
              }
              if [ -n "$root" ]; then
                sync_plugin debug-plugin ${debug-plugin}
                sync_plugin dev-kit ${dev-kit}/dev-kit
              fi

              echo "rsplugins dev shell"
              echo "  lua / luac                    Lua $(lua -v 2>&1 | cut -d' ' -f2) (client runs 5.4.8)"
              echo "  lua-language-server           LSP for editors; docs/api/ holds the API stubs"
              echo "  stylua / selene               Lua formatter / linter"
              echo "  scripts/check-lua.sh          the gate: luac -p, manifests, selene, stylua, LuaLS, tests"
              echo "  scripts/test-lua.sh           run the plugin tests (busted, tests/**/*_spec.lua)"
              echo "  scripts/link-dev-plugins.sh   symlink the beta client's dev_plugins to plugins/"
              echo "  plugins/debug-plugin, plugins/dev-kit  third-party dev plugins (flake inputs, gitignored copies)"
              echo "  scripts/var-dump-receiver.py  receiver for the var-dump plugin"
              echo "  scripts/rsdev.py              dev daemon + CLI: recorder receiver, dev bridge"
            '';
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
