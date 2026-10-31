# Chore Tracker: Mod.io listing and submission notes

Repo-only: this file stays out of the upload zip (`scripts/package-plugin.py` packages
`plugins/chore-tracker/` only), so the dev tooling it describes never reaches players. The
gallery images beside it are described in [README.md](README.md); the upload steps and required
sections are in [docs/submission.md](../../docs/submission.md).

## Before submitting

The development checkout opts into the dev log tee (`lib/dev/tee.lua`, docs/dev-environment.md),
which forwards the plugin's console lines and callback errors to `scripts/rsdev.py` on the same
machine, and into remote eval (`lib/dev/remote.lua`), which runs Lua that script sends inside
the plugin. Its manifest asks for `httpAccess` only for the tee. None of it ships:
`scripts/package-plugin.py chore-tracker` builds the upload zip without it, as
[Preparing the zip from this repo](../../docs/submission.md#preparing-the-zip-from-this-repo)
describes. In this plugin it strips:

- the `dev/` link,
- in `main.lua`, the three `-- dev-only:begin`/`-- dev-only:end` spans: the "Dev checkout
  only" paragraph in the header, the four dev lines that require and install the tee and
  remote, and the `remote.expose(...)` block after the state locals, each with its comment,
- the `remote.shutdown()` and `tee.shutdown()` lines in `PluginShutdown`, each ending in
  `-- dev-only`, and
- `"httpAccess"` and `urls.rsdev` in `plugin.json`, leaving no `urls` and no
  `optionalPermissions`.

A new dev line goes inside a marked span or carries the trailing marker; one left unmarked
fails the build at `check-submission.sh`. The Mod.io text below ("This plugin requests no
permissions") is true only of the packaged zip.

## Mod.io summary

The Profile's Summary field (shown under the screenshot on the list page; 10-250 ASCII
characters):

```text
Track your daily, weekly and monthly RS3 chores in one window. Pick the ones you do and tick them off; shop runs and many more tick themselves.
```

## Mod.io description

Paste this into the Profile's Description field. It is ASCII and carries the four required
sections (Email, EULA, Permissions, Data Protection), the EULA paragraph verbatim from
docs/submission.md.

```markdown
Chore Tracker is a checklist for RuneScape's repeatable chores: the daily, weekly and monthly tasks such as the Daily Challenge, Soul Reaper or the Giant Oyster.

Pick the chores you do with the settings button, then click a chore in the list to tick it off. Ticks clear themselves at the game's resets, in UTC: daily chores at 00:00, weekly ones on Wednesday and monthly ones on the 1st. Drag a chore by its grip to put your list in your own order. While you drag a chore by its grip (mouse button held), an invisible layer covers the screen so the drag can follow the pointer; it takes no game input and shrinks back over the grip on release.

Many chores tick themselves: shop runs when you buy from their shops, Dell Monti's and the Weird Old Man's goods when their notes arrive in your backpack, Invention machines when you collect from them, and others, such as the Daily Challenge and Bert's sand, when the game's own record of your progress shows them done. A chore done in several places, such as a shop run, the herb run or Penguin Hide and Seek, shows how many you have done and ticks once you reach a count you can set under How many to do in settings; lowering the count to what you have already done ticks it. Only a change seen while the plugin runs ticks a chore, so a chore done while it was off needs a tick by hand. The info button in the plugin lists every chore as Automatic, Unproven (should tick itself, not yet checked in game) or Manual. Unproven detections are inferred from the names the game gives its vars and shop inventories, and are labelled as such in the plugin.

The plugin never displays a game var's value or a machine's contents. It ticks a chore only when one of your own vars or inventories changes the way doing the chore changes it (for example you spotted a penguin, bought the Black Marketeer's offer, or collected from an Invention machine). The only number it shows from these reads is how many parts of a chore you have done this period, which you did yourself. It reads your position only to tell a collection or bonus XP claim made beside Dell Monti, the Weird Old Man or Aster from one made elsewhere.

The menu button at the window's top-right corner folds it into a small strip showing your next chore, which a click ticks. When the plugin ticks a chore, or you finish a period's chores, a short popup celebrates it; settings turn the popups or their sound off.

Your chores are saved per character, so each character has its own list.

Requires the PrettyUI plugin.

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
- your position (to tell when you stand beside Dell Monti or the Weird Old Man, or beside Aster in Fort Forinthry);
- the contents of your backpack;
- the stock of a shop you have open;
- what your Invention machines hold;
- your own character's game vars for the chores it ticks from them, such as the Daily Challenge and Bert's sand;
- and the chores you pick and tick.

It shows popups about those chores, using the game's own sounds and sprites, and each chore with one of the game's own item icons or sprites.
This information is not transmitted outside of the plugin under any circumstances.
Stored on this device in the plugin's PersistentDB, under your character's display name: your picked chores in your order, when each chore was last ticked (by you or by the plugin), when you last did each part of a chore with several parts (each shop of a shop run, herb patch, bloodwood tree, farm trough, penguin, port voyage, Thalmund slot and Shattered Worlds challenge) for every such chore whether picked or not, and any count you changed under How many to do. Stored the same way for all characters: the window's position, size and collapsed state, where the collapsed strip is, and whether celebration popups and their sound are on. Your position is never stored.
For Jagex: I request that the supplied email is hidden from public view.
```
