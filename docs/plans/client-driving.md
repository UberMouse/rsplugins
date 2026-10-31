# Driving the client: OS input and UI probes

Started 2026-10-31. Goal: let Claude develop plugins with fewer hand-offs. Claude should be able
to click, move the pointer and type in the beta client and in Bolt (so it can recover from a
crash on its own), and drive a plugin's UI from probes where it can, so it doesn't have to click.

## Decisions (the user's)

- **Input scope: Bolt, the console, and plugin-made UI.** OS-level input goes only to the Bolt
  launcher, the client's login and lobby, the client console, and components a plugin created.
  It never goes to the 3D world, game interfaces, action bars, or anything else that sends an
  action to the server. Why: Jagex's rules forbid third-party software that automates client
  input, and the beta character belongs to the user's real account.
- **Relaunch after a crash by clicking through Bolt** (Play, the lobby, then `pon dev-bridge`
  typed into the console). Not a direct `rs3linux` launch with saved `JX_SESSION_ID` /
  `JX_CHARACTER_ID` / `JX_DISPLAY_NAME`, which would mean storing login tokens.
- **UI probes run inside the plugin, with a handler registry.** A `lib/dev/` module a plugin
  opts into, like the tee, runs eval snippets in that plugin's own environment. The plugin's UI
  helpers keep named handles to their click handlers so a probe can fire one.

## What the first probes settled (2026-10-31)

Details and evidence are in [api-concepts.md](../api-concepts.md) under "The client window on
X11" and UI.

- **Coordinates:** at interface scale 100, one plugin-layer unit is one window pixel, with its
  origin at the window's top-left. A component's `xyGlobal` plus half its size is the point to
  click.
- **Clicks:** XTEST (`xdotool click`) reaches plugin layers; XSendEvent (`click --window`) doesn't.
  XTEST moves the user's real pointer and needs focus, which i3 gives to whatever window is under
  the pointer.
- **Keys:** XTEST reaches the console (Alt+\` opens it, typing and Return run a command).
- **Bridge-side setters work across plugins:** the bridge found another plugin's Slider on the
  plugin layer and its `SetValue(v, true)` fired that plugin's `ONSELECTIONCHANGED`. So Lists,
  Sliders, ComboFields and the like need no opt-in. `ONCLICK`/`ONHOLD`/`ONSCROLLWHEEL` layers
  (all of chore-tracker's rows, stepper and grips) have no API trigger: those need the in-plugin
  route or a real click.

## Slices

Each slice ends with a check-in with the user.

1. **Probes** (done, above).
2. **Pointer commands** (done 2026-10-31): `rsdev.py ui`, `click`, `move` and `drag`, documented
   in [dev-environment.md](../dev-environment.md#input-ui-click-move-drag). A point must be on a
   shown, non-clickthrough plugin component, which the bridge vouches for by walking the plugin
   layer (`plugins/dev-bridge/probes/ui-tree.lua`). The audit trail is `dumps/rsdev/input.log`.
   Keyboard input was left out: a probe showed a plugin can't tell whether the console is open
   (api-concepts), and a key sent with it closed could hit an ability keybind. It moves to slice 4,
   where `pon dev-bridge` is the only thing typed.
3. **In-plugin eval and the handler registry:** `lib/dev/eval.lua`, commands over the tee's
   channel (the tee's post becomes a sync that returns commands),
   `rsdev.py eval --plugin <name>`. Then named handles in chore-tracker's `rows`, `stepper` and
   `grips`. `check-submission.sh` has to catch what's left of it in a copy for upload.
4. **Crash recovery through Bolt:** notice the crash (the `rs2client` process or the bridge
   session is gone), screenshot Bolt, click Play, get through the lobby, then
   `pon dev-bridge` from the console. After a crash, the "diff before another test" rule
   still applies.

## Open questions

- Bolt's window: its `WM_CLASS`, and whether `maim` captures it (it's CEF).
- How to tell the console is open before typing (needed for slice 4). Plugins can't (they get
  `KeyDown` either way). Options: (a) Claude checks a shot between Alt+\` and typing; (b) a
  pixel test on the console's band in a shot, compared with one taken just before the toggle;
  (c) type only while the bridge is down (after a relaunch), when no plugin is running but the
  game still takes keys, so this doesn't remove the risk by itself.
- The login and lobby screens run no plugins, so the bridge can't vouch for a click target
  there. Raw coordinates are allowed only while the bridge is disconnected?
- Other interface scales than 100.
- The double click pair after XSendEvent + `windowfocus --sync` + XTEST (api-concepts).
