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
    # Third-party dev plugins for the beta client, linked into plugins/ by the shellHook. Pinned
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

              # Same rule for the third-party dev plugins: plugins/<name> is what the client's
              # dev_plugins symlink exposes, and the folder name is the plugin's console name.
              # dev-kit keeps its plugin in a dev-kit/ subfolder of the repo.
              # A link whose target has no main.lua means upstream moved its plugin folder: warn,
              # since the link would otherwise dangle silently.
              if [ -n "$root" ] && { [ -L "$root/plugins/debug-plugin" ] || [ ! -e "$root/plugins/debug-plugin" ]; }; then
                ln -sfn ${debug-plugin} "$root/plugins/debug-plugin"
                [ -f ${debug-plugin}/main.lua ] || echo "warning: debug-plugin input has no main.lua" >&2
              fi
              if [ -n "$root" ] && { [ -L "$root/plugins/dev-kit" ] || [ ! -e "$root/plugins/dev-kit" ]; }; then
                ln -sfn ${dev-kit}/dev-kit "$root/plugins/dev-kit"
                [ -f ${dev-kit}/dev-kit/main.lua ] || echo "warning: dev-kit input has no dev-kit/main.lua" >&2
              fi

              echo "rsplugins dev shell"
              echo "  lua / luac                    Lua $(lua -v 2>&1 | cut -d' ' -f2) (client runs 5.4.8)"
              echo "  lua-language-server           LSP for editors; docs/api/ holds the API stubs"
              echo "  stylua / selene               Lua formatter / linter"
              echo "  scripts/check-lua.sh          the gate: luac -p, manifests, selene, stylua, LuaLS, tests"
              echo "  scripts/test-lua.sh           run the plugin tests (busted, tests/**/*_spec.lua)"
              echo "  scripts/link-dev-plugins.sh   symlink the beta client's dev_plugins to plugins/"
              echo "  plugins/debug-plugin, plugins/dev-kit  third-party dev plugins (flake inputs, gitignored links)"
              echo "  scripts/var-dump-receiver.py  receiver for the var-dump plugin"
            '';
          };
        }
      );

      formatter = forAllSystems ({ pkgs, ... }: pkgs.nixfmt-tree);
    };
}
