# Chore Tracker: Mod.io listing and submission notes

Repo-only: `scripts/package-plugin.py` packages `plugins/chore-tracker/` alone, so this file never
reaches players. [README.md](README.md) describes the gallery images beside it, and
[docs/submission.md](../../docs/submission.md) has the upload steps and required sections.

## Before submitting

The development checkout opts into two dev tools: the log tee (`lib/dev/tee.lua`), which forwards
the plugin's console lines and callback errors to `scripts/rsdev.py` on the same machine, and
remote eval (`lib/dev/remote.lua`), which runs Lua that script sends inside the plugin. The
manifest's `httpAccess` is for the tee alone.

`scripts/package-plugin.py chore-tracker` builds the zip without them
([Preparing the zip from this repo](../../docs/submission.md#preparing-the-zip-from-this-repo)).
In this plugin it strips:

| Where | What |
|---|---|
| `dev/` | the link |
| `main.lua` | three `-- dev-only:begin`/`-- dev-only:end` spans: the header's "Dev checkout only" paragraph, the four lines that require and install the tee and remote, and the `remote.expose(...)` block after the state locals |
| `PluginShutdown` | the `remote.shutdown()` and `tee.shutdown()` lines, each ending in `-- dev-only` |
| `plugin.json` | `"httpAccess"` and `urls.rsdev`, leaving no `urls` and no `optionalPermissions` |

The Mod.io text below says "This plugin requests no permissions", which is true only of the
packaged zip.

## Mod.io summary

The Profile's Summary field (10-250 ASCII characters):

```text
Track your daily, weekly and monthly chores in one window. Pick the ones you do and tick them off; shop runs and many more tick themselves.
```

## Mod.io description

Paste this into the Profile's Description field. It is ASCII and has the four required sections.
The EULA paragraph is Jagex's wording, typos included, copied from docs/submission.md: don't edit
it.

```markdown
Chore Tracker is a checklist for RuneScape's daily, weekly and monthly chores, such as the Daily Challenge, Soul Reaper and the Giant Oyster. It needs the PrettyUI plugin.

Pick the chores you do with the settings button, then click a chore in the list to tick it. Each character has its own list. Ticks clear at the game's resets, in UTC: daily chores at 00:00, weekly ones on Wednesday and monthly ones on the 1st. Drag a chore by its grip to reorder your list. During the drag only, an invisible layer covers the screen so the drag can follow the pointer; it takes no game input and shrinks back over the grip on release.

Many chores tick themselves: shop runs when you buy from their shops, Dell Monti's and the Weird Old Man's goods when their notes arrive in your backpack, Invention machines when you collect from them, and others, such as the Daily Challenge and Bert's sand, when the game's record of your progress shows them done. A chore with several parts, such as a shop run, the herb run or Penguin Hide and Seek, shows how many you have done and ticks at the count you set under **How many to do** in settings. Only a change seen while the plugin runs ticks a chore, so a chore done while it was off needs a tick by hand. The info button lists every chore as **Automatic**, **Manual** or **Unproven**: inferred from the names the game gives its vars and shop inventories, and not yet checked in game.

The plugin never shows a game var's value or a machine's contents. It ticks a chore only when one of your own vars or inventories changes the way doing that chore changes it, and the only number it shows from them is how many parts of a chore you have done this period.

The menu button folds the window into a strip showing your next chore, which a click ticks. A popup celebrates each ticked chore and each finished period; settings turn the popups or their sound off.

Beyond PrettyUI's public API, shell/prettyui_internals.lua uses a few of PrettyUI 1.2.0's private fields and methods and registers one hidden overlay on the window, to keep the drag grips above the window and its resize handles and cursors working. Every use is guarded, so a PrettyUI update loses those touches instead of causing an error.

## Email
The contact email address for this plugin is ubermouse894@gmail.com.

## EULA
By submitting a Plugin (as defined in Schedule 4 of the EULA), you acknowledge that you agree to the terms of the Jagex End User License Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it be reference) and acknowledge that such terms are legally binding on you. If you do not agree to the terms of the EULA, you must not submit a Plugin or use the Plugin functionality anyway. In such circumstances, Jagex does not licence the software to you, or grant you any of the relevant rights relating to the submission of Plugins set out in the EULA and you will not be permitted to access or use the Plugin functionality in any way whatsoever.

## Permissions
This plugin requests no permissions.

## Data Protection
This plugin uses the following information:
- the game clock;
- your own character's display name (only as the key your chores are saved under);
- your position (only to tell when you stand beside Dell Monti or the Weird Old Man, or beside Aster in Fort Forinthry);
- the contents of your backpack;
- the stock of a shop you have open;
- what your Invention machines hold;
- your own character's game vars for the chores it ticks from them, such as the Daily Challenge and Bert's sand;
- and the chores you pick and tick.

It shows each chore with one of the game's own item icons or sprites, and its popups use the game's own sounds and sprites.
This information is not transmitted outside of the plugin under any circumstances.
The plugin stores, on this device in its PersistentDB, under your character's display name: your picked chores in your order, when each chore was last ticked, when you last did each part of a chore with several parts (for every such chore, picked or not), and any count you changed under **How many to do**. For all characters it stores the window's position, size and collapsed state, where the collapsed strip is, and whether celebration popups and their sound are on. It never stores your position.
```
