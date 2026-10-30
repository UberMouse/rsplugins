# Chore Tracker

A checklist for RuneScape's repeatable chores, the daily, weekly and monthly tasks such as the
Daily Challenge, Soul Reaper or the Giant Oyster. Pick the ones you do, tick them off as you go,
and they clear themselves when the game's reset comes round. A few chores also tick themselves:
the shop runs, when you buy from one of their shops, Dell Monti's and the Weird Old Man's,
when their notes arrive, and a few more, such as the Daily Challenge and Bert's sand, when the
game's own record of your progress shows them done. It only reads what the game already gives
your client, never does anything in game for you, and sends nothing anywhere.

## Using it

- **Opening it.** Enable the plugin and a window titled **Chores** opens. On the first run it
  says no chores are picked yet.
- **Picking chores.** Click the settings button at the top left of the window. Above the chores
  is a Celebrations section (see below). Every chore is listed under Daily, Weekly and Monthly;
  ones that are bought from a shop end in "(shop)". Each is a row with its icon, its name and a
  tick box: click anywhere on a row to pick it (the box ticks) or click again to drop it.
  Changes save straight away. To return to your list, click the back button in the window's top-right
  corner, where the menu button usually sits. It stays there however far down you have scrolled.
  (Collapse the window from the list, not from here.)
- **Ticking chores.** The list shows the chores you picked under Daily, Weekly and Monthly
  headings, each with a count such as "Daily  2/5". Each chore's row has an icon from the game
  (the reward or the thing you handle, a gold XP or skill medallion when the reward is XP, the
  General Store icon for the general shops), its name, and a tick box at the right. Click
  anywhere on a row when you've done the chore: it stays where it is, ticked, with its icon and
  name dimmed. Click it again to untick it. Over any row, in the list or in settings, the
  cursor becomes the hyperlink hand and the tick box lights up.
- **Putting chores in your own order.** Each row in the list has a grip at its left, a menu
  icon, where the cursor changes to a push cursor. Press the grip and drag the chore up or
  down: it follows the pointer, and the other chores of its period slide apart to show where it
  will land. Let go to drop it there. A chore stays within its own period (Daily, Weekly or
  Monthly). Drag past the top or bottom of the list and the list scrolls. The pointer may leave
  the window while you drag; the chore drops wherever you let go. During a drag only, an
  invisible layer over the screen keeps the drag following the pointer; it takes no game input
  (the mouse button is already held for the drag) and goes as soon as the button is released or
  the drag otherwise ends. A click on the grip ticks nothing; click the rest of the row for
  that. A chore you pick later goes to the end of its
  period.
- **Long names.** A name too long for the window is shortened with "..." so it stops before
  the tick box; make the window wider and more of it shows. Hover a shortened row and its
  tooltip starts with the full name.
- **Details.** Hover a chore for its description and its RuneScape Wiki links. The links are
  shown as text, because plugins can't open web pages.
- **Collapsing it.** The menu button at the top-right corner of the window, where
  a close button usually sits, folds the window into just that button, at the same spot. Click
  the button to open the window again: it opens leftwards and down from the button.
- **Moving it.** Drag the window by its title bar, and resize it from its edges or corners,
  which show a resize cursor when you hover them. While it is collapsed, hold **Alt** and drag
  the button to move it. Alt-dragging only works with the console closed.

- **Celebrations.** When the plugin ticks a chore you picked, a small popup, "CHORE COMPLETE"
  with the chore's name, shows upper-middle of the screen with a short jingle. When your picked
  chores of a period are all done, a bigger one follows with a grander jingle: "DAILIES
  COMPLETE", "WEEKLIES COMPLETE" or "MONTHLIES COMPLETE". That one also shows when you tick the
  last one by hand, and again each time your picked chores become all done (unticking and
  re-ticking the last one, or picking another chore and ticking it). Ticking a chore by hand
  never shows the chore's own popup, and unticking, picking or unpicking chores, and logging in,
  show nothing. Popups appear one at a time and last about four seconds, whether the window is
  open, collapsed or in settings. In the settings view, under **Celebrations**, untick
  "Celebration popups" to turn them off, or "Popup sound" to keep them quiet. Both are saved for
  all characters.

## Chores it ticks for you

Ticking by hand still works for every chore, these included: a chore ticked either way stays
ticked until its reset, and unticking one by hand changes nothing below.

- **Shop runs.** Buy anything at any of a chore's shops and the chore ticks itself for the
  period, whether or not you picked it, so picking it later shows it done. The plugin can tell
  because the game only sends a shop's stock while that shop is open, and the stock is yours
  alone: a line that goes down is you buying. A restock or something you sell to the shop
  doesn't count. A chore with more than one shop shows how many you have bought from this
  period, as "Feather Shop Run (1/4)", and its tooltip lists each shop as "bought" or "not
  yet". A shop the game has in two versions, before and after a quest, counts once, bought
  from either. A count changes in its row as you buy, without moving the list.
- **Collecting from Dell Monti and the Weird Old Man.** Their goods arrive as banknotes in
  your backpack with no shop open, so the chore ticks when those notes go up in your backpack
  while you are within 10 tiles of the giver, on the same floor: Dell Monti's apple or
  pineapple notes, or the Weird Old Man's potato cactus notes (outside the Kalphite Lair;
  *unproven*, as nobody has checked his yet). Any rise counts, wherever the notes came from:
  taking some out of the bank, a trade or picking them up near the giver ticks the chore too.
- **Seen from game vars.** The game keeps a record of your character's progress in numbered
  values called vars, and sends your client yours as they change. A chore below ticks when
  one of these changes so that it shows the chore done:

  | Chore | Ticks when |
  |---|---|
  | Sand from Bert | the game marks Bert's sand claimed |
  | Flax from Geoffrey | the game marks Geoffrey's flax given |
  | Pure Essence from Wizard Cromperty | the game marks Cromperty's essence claimed |
  | Logs from Coeden | the game marks Coeden's logs claimed |
  | Daily Challenge | you claim a challenge's reward in the challenge window: any claim ticks it for the day, even before you've claimed all three |
  | Advance Time (*unproven*) | the spell's last charge of the week is used |
  | Divine Locations (*unproven*) | you have gathered the day's limit from divine locations |
  | Crystal Tree Blossom (*unproven*) | the game records today as the day you last took blossoms |
  | Sinkholes (*unproven*) | you have played two sinkholes today |
  | Big Chinchompa (*unproven*) | the game marks today's Big Chinchompa game played |
  | Fixate Charges (*unproven*) | you have used three fixate charges today |
  | Runesphere (*unproven*) | the game marks today's dust handed in |
  | Soul Reaper (*unproven*) | the game marks the week's Soul Reaper cap reached |
  | Thalmund's Wares (*unproven*) | you have bought every one of Thalmund's four slots up to its limit |
  | Tears of Guthix (*unproven*) | the game marks the week's tears collected (the game may not send this one, so it may never tick) |
  | Herby Werby (*unproven*) | the game marks the week's Herby Werby completed |
  | Wisps of the Grove (*unproven*) | the game marks the week's Wisps of the Grove completed |
  | Shattered Worlds (*unproven*) | the game marks all three of the week's reward challenges (bronze, silver and gold) complete |
  | Aquarium Treasure Chest (*unproven*) | the game marks your aquarium's treasure chest used |
  | Agoroth (*unproven*) | you have defeated Agoroth twice this week |
  | Replay Broken Home (*unproven*) | the game marks the week's Broken Home replay completed |
  | Soul Supplies (*unproven*) | the game marks Lupe's supplies claimed |
  | Effigy Incubator (*unproven*) | the game marks the month's Effigy Incubator completed |

  *Unproven* ones haven't been checked in game yet. The four free collections keep the
  weekly reset the list gives them, although the game lets you claim each daily.

  **Only a change the plugin sees ticks a chore.** For 10 seconds after you log in or the
  plugin starts, while the game sends your vars, nothing ticks. So a chore done while the
  plugin was off, or already done when you log in, isn't ticked: tick it by hand. The window
  never shows a var's value.

The shops each chore watches. Those marked *unproven* were matched by name to the game's own
list of shop inventories but no purchase there has been checked yet; they tick the same way.

| Chore | Shops |
|---|---|
| Feather Shop Run | Gerrant (Port Sarim), Lumbridge Fishing Supplies, Harry (Catherby), Shantay Pass |
| Vial of Water Packs | Jatix (Taverley), Obli (Shilo Village), Lady Meilyr (Prifddinas), Jossik (Lighthouse), Granny Rowan (Fort Forinthry, *unproven*) |
| Yak Hide | Vanligga (Jatizso) |
| Feathers of Ma'at | Feathers of Ma'at (Sophanem) |
| Broad Arrowheads | Turael (Burthorpe), Sumona (Pollnivneach) |
| Rune Shop Run | Aubury (Varrock), Betty (Port Sarim), Ali Morrisane (Al Kharid), Carwen Essencebinder, Void Knight Magic Store, Magic Guild (Yanille), Tutab (Ape Atoll), Lundail (Mage Arena), Rune store (Anachronia), Baba Yaga (Lunar Isle), Mage of Zamorak (Wilderness), the last five *unproven* |
| Meat Packs | Chargurr (Oo'glog, *unproven*) |
| Planks from Razmire | Razmire Keelgan (Mort'ton, *unproven*) |
| Seaweed and Pineapples | Arhein (Catherby) |

Not watched yet, so tick it by hand: Bandit Duty Free (no match for Noterazzo's shop was found
in the game's list).

## When chores reset

By the game clock, in UTC:

- **Daily** chores at 00:00 each day.
- **Weekly** chores at 00:00 on Wednesday.
- **Monthly** chores at 00:00 on the 1st of the month.

A ticked chore unticks by itself when its reset passes, even with the window open.

## What it remembers

- **Your picks, their order and your ticks, per character.** They are saved each time you change
  them, under your character's display name, so each character on the same computer has its own
  list. While you are logged out the window says "Log in to see your chores".
- **Where the window is**, for all characters: its position, its size, whether it is collapsed,
  and where the collapsed button is. These are saved within a second of a change and restored
  next time, moved back on screen if they no longer fit.
- **Whether celebrations are on, and with sound**, for all characters.
- Until the game clock is available (just after logging in), the window shows "Waiting for the
  game clock" and chores can't be ticked.

## Requirements

- **PrettyUI** (mod.io 6398181), the interface library the window is built with. It is a
  required dependency: install it too.
- **No permissions.** The submitted plugin requests none; the development checkout's manifest
  asks for `httpAccess` only for the dev log tee, which is stripped before submitting. The plugin
  reads the game clock, your own character's display name and position, your backpack, the stock
  of an open shop it watches, and your own character's game vars for the chores in the "Seen from
  game vars" table. Plugins can read all of these without one.

## Credits

The chore list (names, descriptions, wiki links and reset periods) comes from
[dailyscape](https://github.com/dailyscape/dailyscape.github.io), used under its MIT licence.
`data/chores.lua` holds the copy, the licence text, and how to regenerate it.

## Console lines

Everything the plugin logs carries the tag `[CHORES]`: loading, collapsing and expanding,
character changes, waiting for the clock, each celebration popup shown
(`[CHORES] celebrate <chore id>`, or `[CHORES] celebrate <period> cleared`) and each chore
dragged to a new place (`[CHORES] moved <chore id> to <n> in <period>`, `<n>` its place in
the period from 1). It never logs your display name. Grep regex:
`\[CHORES\]`.

A purchase that ticks a chore, or is the period's first at that shop, logs
`[CHORES] purchase <chore id> at <shop>` (such as
`[CHORES] purchase feather-shop-run at Gerrant, Port Sarim`), and a collection that ticks its
chore logs `[CHORES] collected <chore id> near <giver>` (such as
`[CHORES] collected oldman-potato-cactus near the Weird Old Man`), and a chore ticked from
the game's vars logs `[CHORES] seen <chore id> done (<var>)`, naming the var whose change
ticked it (such as `[CHORES] seen bert-sand done (HANDSAND_BUCKETS_CLAIMED_TODAY)`). A watched
var the game no longer has is logged once at start as `[CHORES] unknown var <name>; not
watched`, and its chores are left to tick by hand. Likewise an icon the game no longer has
is logged once, when a row first needs it, as `[CHORES] unknown icon id.Obj.<name>; its rows
show no icon` (or `id.Sprite.<name>`), and its rows show no icon. Grep regex:
`\[CHORES\] (purchase|collected|seen|celebrate)`.

## Before submitting

The development checkout opts into the dev log tee (`lib/dev/tee.lua`, docs/dev-environment.md),
which forwards the plugin's console lines and callback errors to `scripts/rsdev.py` on the
same machine. None of it ships. Remove all of it first:

- the `dev/` symlink in this folder,
- the two tee lines at the top of `main.lua` (`local tee = require("dev/tee")` and
  `if tee then tee.install(...) end`, with the comment above them),
- the `if tee then tee.shutdown() end` line in `PluginShutdown` (with its comment),
- `"httpAccess"` from `optionalPermissions` in `plugin.json`, and
- `urls.rsdev` from `plugin.json` (leaving no `urls` and no `optionalPermissions`).

Then run `scripts/check-submission.sh chore-tracker` on the prepared copy (see the script's
header); it must pass before upload. The Mod.io text below ("This plugin requests no
permissions") is true only after that check passes.

## Files

| File | What |
|---|---|
| `main.lua` | The window, its collapsed button, the two views, and following the login and clock |
| `shell/detect.lua` | Seeing shop runs and collections done, from shop stock, the backpack and your tile |
| `shell/vars.lua` | Seeing chores done from your own game vars, ticking only on a change it sees |
| `shell/popups.lua` | Showing celebration popups one at a time, first in first out |
| `shell/rows.lua` | One chore's row in the list or settings: its icon, text and tick box (and a list row's grip), changed in place |
| `shell/grips.lua` | Dragging a list row by its grip: the press targets over the grips, the drag and the drop |
| `shell/prettyui_internals.lua` | Keeping the window's scroll, wheel, grips and resize cursors working across PrettyUI versions |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `core/period.lua` | When each reset period began (pure arithmetic on epoch minutes) |
| `core/state.lua` | Picks, ticks and shop purchases, and whether a chore is done now |
| `core/shops.lua` | Spotting a purchase in a shop's counts, and notes rising near a giver |
| `core/vars.lua` | Whether a chore's var rule holds on a set of var values, and the RuneDay |
| `core/view.lua` | What the list shows, as plain data |
| `core/fit.lua` | Cutting a row's name short with "..." so it fits before the tick box |
| `core/layout.lua` | The saved window layout, read back and kept on screen |
| `core/listlayout.lua` | Where the list's headings and rows go in the window |
| `core/reorder.lua` | Where a dragged row and its neighbours go, and when the list scrolls under a drag |
| `core/celebrate.lua` | Which celebrations a change to the picks and ticks earns |
| `core/settings.lua` | The celebration settings, defaults and reading them back |
| `data/chores.lua` | The dailyscape chore list (generated) |
| `data/shops.lua` | The shops each shop-run chore watches (hand-written) |
| `data/collections.lua` | Who each collection chore is collected from, where, and their notes (hand-written) |
| `data/vars.lua` | The chores seen from game vars and each one's rule (hand-written) |
| `data/icons.lua` | Each chore's icon, a built-in item or interface sprite (hand-written) |

The tests are in `tests/chore-tracker/` and run against the repo's mock of the plugin API
(`docs/testing.md`).

## Mod.io description

```markdown
## Email
The contact email address for this plugin is you@example.com.

## EULA
By submitting a Plugin (as defined in Schedule 4 of the EULA), you acknowledge that you agree to the terms of the Jagex End User License Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it be reference) and acknowledge that such terms are legally binding on you. If you do not agree to the terms of the EULA, you must not submit a Plugin or use the Plugin functionality anyway. In such circumstances, Jagex does not licence the software to you, or grant you any of the relevant rights relating to the submission of Plugins set out in the EULA and you will not be permitted to access or use the Plugin functionality in any way whatsoever.

## Permissions
This plugin requests no permissions.

## Data Protection
This plugin uses the following information: the game clock, your own character's display name and position, the contents of your backpack, the stock of a shop you have open, your own character's game vars for the chores in the "Seen from game vars" table above (to see them done), and the chores you pick and tick. It shows popups about those chores, using the game's own sounds and sprites, and each chore with one of the game's own item icons or sprites.
This information is not transmitted outside of the plugin under any circumstances.
Your picked chores in your order, the ones you ticked, and when you last bought from each watched shop, are stored on this device in the plugin's PersistentDB, under your character's display name, with the window's position, size and collapsed state. Your choices of whether to show celebration popups and play their sound are stored in the same way, for all characters.
```
