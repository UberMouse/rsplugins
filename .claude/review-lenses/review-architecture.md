# Review lens: architecture, duplication & module structure

## Part A — duplicated code

Copy-pasted functions with minor variations; repeated logic that should be one local helper or a
shared module inside the plugin; near-identical event handlers. Look within the change and
between the change and the plugin's existing code. Plugins do not share code with each other
except through declared dependencies, so duplication *across* plugins is not a finding unless
the change also adds a dependency it could have used.

## Part B — architecture

- **Functional core, imperative shell.** Pure logic (geometry, parsing, encoding, state
  transitions, "what should be drawn") belongs in functions that take plain values and return
  plain values, with no `Event`, UI, `PersistentDB`, `HTTPRequest`, entity or `log` calls inside.
  Callbacks and top-level code in `main.lua` orchestrate. A change that threads API calls through
  logic that could have been pure makes it impossible to run under plain `lua` and harder to
  moderate. A core function calling back into the shell is a finding.
- **Module boundaries.** Extra modules return a table (or a constructor when callers need
  separate state, since `require` caches). A module that reaches into another's internals, or
  that relies on being required in a particular order, is fragile.
- **Global namespace.** Everything is `local` except the lifecycle hooks the client looks up by
  name. A plugin-wide mutable global (even one selene allowed through `rs.yml`) shared between
  modules is a finding.
- **Fit with the surrounding plugin.** Read the rest of the plugin: its `say()` logging helper,
  its constants block, its sliced-work pattern, its key handling. A change that invents a second
  way of doing one of those is a finding.
- **Overengineering**: abstraction with one caller, configuration nobody sets, generality for
  hypothetical plugins. Moderators read every line, and each extra one is a line they must
  understand. **Underengineering**: a plugin with no way to turn its overlay off, no handling for
  logged-out or loading states, no recovery after an error mid-job.
- **Files and naming**: plugin folder names have no spaces (they are console names); modules sit
  inside the plugin folder; names follow the plugin's existing convention.

## Part C — data shapes

- Tables used as records should have one shape: a field that is sometimes a number and
  sometimes a string, or present on some records only, pushes nil checks onto every reader.
- Packed integer keys, bit flags and parallel arrays are fine when commented; uncommented, a
  reader cannot tell what `k = lz * SIZE + lx` means.
- Magic numbers that are API constants (shape types, value types, key codes) belong in a named
  table with a pointer to where the values come from in the docs.

## Part D — house conventions

- **Return-type annotations** (`CLAUDE.md`): every function the change adds or changes that
  returns a value carries a LuaLS `---@return <type>` line (`---@return integer`,
  `---@return string?` for a nil-able return, `---@return boolean ok, string? err` for several),
  unless the type is complex enough that it needs inferring. Functions that return nothing need
  none. An annotation that disagrees with what the function returns (a nil path under a non-`?`
  type) is a finding too. Functions the change did not touch are out of scope.
