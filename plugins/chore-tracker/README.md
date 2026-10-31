# Chore Tracker

A checklist for RuneScape's repeatable chores, the daily, weekly and monthly tasks such as the
Daily Challenge, Soul Reaper or the Giant Oyster. Pick the ones you do, tick them off as you go,
and they clear themselves when the game's reset comes round. A few chores also tick themselves:
the shop runs, when you have bought from their shops (all of them, or as many as you set),
Dell Monti's and the Weird Old Man's,
when their notes arrive, and a few more, such as the Daily Challenge and Bert's sand, when the
game's own record of your progress shows them done. It only reads what the game already gives
your client, never does anything in game for you, and sends nothing anywhere.

## Using it

- **Opening it.** Enable the plugin and a window titled **Chores** opens. On the first run it
  says no chores are picked yet.
- **Picking chores.** Click the settings button at the top left of the window. Above the chores
  are a Celebrations section and a Shop runs section (see below). Every chore is listed under
  Daily, Weekly and Monthly,
  and within Daily and Weekly under a gold subheading for its kind: Activities, Combat,
  Skilling, Upkeep, Free supplies (handed out by someone who is no shop) and Shops, each in
  alphabetical order. Monthly has too few chores to need them. Each is a row with its icon, its
  name and a tick box: click anywhere on a row to pick it (the box ticks) or click again to drop it.
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
  a close button usually sits, folds the window into a small strip with that button at the same
  spot. The strip shows your next chore not yet done, as "Daily: Sand from Bert": the first
  unticked one in your Daily order, or once those are all done the first in Weekly, then
  Monthly. Click it to tick that chore, as you would its row in the list, and the strip moves on
  to the next. With nothing left it says "All chores done" (or "No chores picked"). The strip is
  as wide as the longest of your picked chores, so it keeps its size while you work through
  them. It shows no tooltip. Click the menu button to open the window again: it opens leftwards
  and down from the button.
- **Info.** The info button, beside the settings button, opens a short help on the ideas
  above, then every chore under one of three headings, each with its count: **Automatic**
  (ticks itself, checked in game), **Unproven** (should tick itself, not yet checked in game)
  and **Manual** (tick it by hand). Each row shows the chore's icon and name, with its period
  after a name offered in two periods ("Dream of Iaia XP (weekly)"); hover one for the same
  tooltip as in settings. The rows can't be clicked. The back button in the window's top-right
  corner returns to the list. The help fills the window's width. After you resize the window,
  once its width has stayed put for about half a second, the view is laid out again for the new
  width, at the same scroll.
- **Moving it.** Drag the window by its title bar, and resize it from its edges or corners,
  which show a resize cursor when you hover them. While it is collapsed, hold **Alt** and drag
  the strip to move it. Alt-dragging only works with the console closed.

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

- **Shop runs.** Buy anything at one of a chore's shops and the plugin records that shop as
  bought from this period, whether or not you picked the chore, so picking it later shows the
  period's truth. The plugin can tell because the game only sends a shop's stock while that
  shop is open, and the stock is yours alone: a line that goes down is you buying. A restock or
  something you sell to the shop doesn't count. A chore with one shop ticks itself on a
  purchase there. A chore with more than one ticks once you have bought from as many of its
  shops as it needs this period: all of them unless you set fewer under **Shop runs** in the
  settings view (you may skip a shop you can't reach yet, say). Its row shows how many of
  those it needs you have bought from, as "Feather Shop Run (1/4)" (never more than it needs),
  and its tooltip gives the same count and lists every shop as "bought" or "not yet". A shop
  the game has in two versions, before and after a quest, counts once, bought from either. A
  count changes in its row as you buy, without moving the list.
- **Shops needed.** In the settings view, under **Shop runs** (below Celebrations), each chore
  with more than one shop has a line with its name and "[-] 4 of 4 [+]": click the minus or
  plus to set how many of its shops tick it, from 1 to all of them. It starts at all of them,
  saves straight away, and is kept per character, as characters reach different shops.
  Changing it never ticks or unticks the chore: lowered to what you have already bought, the
  chore ticks on your next purchase at one of its shops; raised above it, a tick stays.
- **Collecting from Dell Monti and the Weird Old Man.** Their goods arrive as banknotes in
  your backpack with no shop open, so the chore ticks when those notes go up in your backpack
  while you are within 10 tiles of the giver, on the same floor: Dell Monti's apple or
  pineapple notes, or the Weird Old Man's potato cactus notes (outside the Kalphite Lair;
  *unproven*, as nobody has checked his yet). Any rise counts, wherever the notes came from:
  taking some out of the bank, a trade or picking them up near the giver ticks the chore too.
- **Collecting from your Invention machines** (daily and weekly). Each Invention
  Guild machine keeps what it made in a store the game sends your client wherever you are, and
  only collecting takes from it, so the chore ticks when any machine's store goes down. Filling
  a machine doesn't count.
- **Seen from game vars.** The game keeps a record of your character's progress in numbered
  values called vars, and sends your client yours as they change. A chore below ticks when
  one of these changes so that it shows the chore done:

  | Chore | Ticks when |
  |---|---|
  | Sand from Bert | the game marks Bert's sand claimed |
  | Flax from Geoffrey | the game marks Geoffrey's flax given |
  | Pure Essence from Cromperty | the game marks Cromperty's essence claimed |
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
  | Broken Home Replay (*unproven*) | the game marks the week's Broken Home replay completed |
  | Soul Supplies from Lupe (*unproven*) | the game marks Lupe's supplies claimed |
  | Effigy Incubator (*unproven*) | the game marks the month's Effigy Incubator completed |
  | Archaeology Research | you send out a research team |
  | Miscellania (daily and weekly) | you collect the kingdom's resources |
  | Bakriminel Bolts | you fell one of your bloodwood trees |
  | Player-Owned Farm | you put food in one of the farm's troughs |
  | Herb Run | you plant one of your herb patches: the first patch planted ticks the day's run |
  | God Statues | the game's count of months since you built the statues falls to 0 |
  | Troll Invasion | the game marks the month's Troll Invasion limit reached |
  | Menaphos Obelisk and Scarabs | you have squashed 23 corrupted scarabs today (the last at full reputation) and drained the soul obelisk at all |
  | Goebie Supply Run | you have handed in today's 10 supplies |
  | GWD2 Bounties | Feng gives you a bounty |
  | Clan Citadel Cap | the game marks the quartermaster's weekly XP boost claimed |
  | Rush of Blood | you clear a wave in the week's reward run |
  | Meg's Questions | Meg leaves on her mission after your third answer |
  | Water Filtration | the game records a new clean-out time |
  | Arc Supplies from Rosie | the game marks Rosie's free supplies taken |
  | Giant Oyster | the oyster has been fed both its sea cucumber and its seaweed |
  | Arc Contracts | you complete the day's last contract: 3, plus one for each "contracts per day" upgrade bought |
  | Fort Forinthry Bonus XP | any skill's bonus XP goes up while you stand within 10 tiles of Aster, in the Town Hall: claiming from Aster does that (so does a lamp or star used beside her) |
  | Dream of Iaia Resources (daily and weekly) | every base-camp resource you have workers on has been used down to 0, and one of them just fell (sending the workers elsewhere doesn't tick it) |
  | Dream of Iaia XP (weekly and monthly) | every skilling station you have workers for holds 0 stored XP, and one just fell (sending the workers elsewhere doesn't tick it) |

  How often the two Dream of Iaia chores are due depends on how you split your workers, so
  each is offered in two periods: pick the one that fits.

  *Unproven* ones haven't been checked in game yet. The rest were checked either by doing
  the chore or by setting the var with a developer cheat and seeing the chore tick. The four free collections keep the
  weekly reset the list gives them, although the game lets you claim each daily.

  **Only a change the plugin sees ticks a chore.** For 10 seconds after you log in or the
  plugin starts, while the game sends your vars, nothing ticks. So a chore done while the
  plugin was off, or already done when you log in, isn't ticked: tick it by hand. The window
  never shows a var's value.

The shops each chore watches. Those marked *unproven* were matched by name to the game's own
list of shop inventories but no purchase there has been checked yet; they count the same way.

| Chore | Shops |
|---|---|
| Feather Shop Run | Gerrant (Port Sarim), Lumbridge Fishing Supplies, Harry (Catherby), Shantay Pass |
| Vial of Water Shop Run | Jatix (Taverley), Obli (Shilo Village), Lady Meilyr (Prifddinas), Jossik (Lighthouse), Granny Rowan (Fort Forinthry, *unproven*) |
| Yak Hides from Vanligga | Vanligga (Jatizso) |
| Feathers of Ma'at | Feathers of Ma'at (Sophanem) |
| Broad Arrowhead Shop Run | Turael (Burthorpe), Sumona (Pollnivneach) |
| Rune Shop Run | Aubury (Varrock), Betty (Port Sarim), Ali Morrisane (Al Kharid), Carwen Essencebinder, Void Knight Magic Store, Magic Guild (Yanille), Tutab (Ape Atoll), Lundail (Mage Arena), Rune store (Anachronia), Baba Yaga (Lunar Isle), Mage of Zamorak (Wilderness), the last five *unproven* |
| Meat Packs from Chargurr | Chargurr (Oo'glog, *unproven*) |
| Planks from Razmire | Razmire Keelgan (Mort'ton, *unproven*) |
| Seaweed and Pineapples from Arhein | Arhein (Catherby) |
| Bandit Duty Free | Noterazzo (Wilderness bandit camp) |


## When chores reset

By the game clock, in UTC:

- **Daily** chores at 00:00 each day.
- **Weekly** chores at 00:00 on Wednesday.
- **Monthly** chores at 00:00 on the 1st of the month.

A ticked chore unticks by itself when its reset passes, even with the window open.

## What it remembers

- **Your picks, their order, your ticks and your shop-run counts, per character.** They are
  saved each time you change
  them, under your character's display name, so each character on the same computer has its own
  list. While you are logged out the window says "Log in to see your chores".
- **Where the window is**, for all characters: its position, its size, whether it is collapsed,
  and where the collapsed strip's button is. These are saved within a second of a change and restored
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
  of an open shop it watches, your Invention machines' output, and your own character's game vars for the chores in the "Seen from
  game vars" table. Plugins can read all of these without one.

## Credits

The chore list (names, descriptions, wiki links and reset periods) started as a copy of
[dailyscape](https://github.com/dailyscape/dailyscape.github.io)'s, used under its MIT licence,
and is now kept by hand in edited form. `data/chores.lua` holds it and the licence text.

## Console lines

Everything the plugin logs carries the tag `[CHORES]`: loading, collapsing and expanding,
character changes, waiting for the clock, each celebration popup shown
(`[CHORES] celebrate <chore id>`, or `[CHORES] celebrate <period> cleared`) and each chore
dragged to a new place (`[CHORES] moved <chore id> to <n> in <period>`, `<n>` its place in
the period from 1), and each change to a shop run's count in settings
(`[CHORES] shops needed <chore id> <n>`). It never logs your display name. Grep regex:
`\[CHORES\]`.

A purchase that ticks a chore, or is the period's first at that shop (ticking the chore or
not), logs
`[CHORES] purchase <chore id> at <shop>` (such as
`[CHORES] purchase feather-shop-run at Gerrant, Port Sarim`), and a collection that ticks its
chore logs `[CHORES] collected <chore id> near <giver>` (such as
`[CHORES] collected oldman-potato-cactus near the Weird Old Man`), a collect from an
Invention machine that ticks its chore logs `[CHORES] collected <chore id> from <inventory>`
(such as `[CHORES] collected invention-machine from INVENT_MACHINE_GUILD_3_OUTPUT`), and a chore ticked from
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
same machine, and into remote eval (`lib/dev/remote.lua`), which runs Lua that script sends
inside the plugin. None of it ships. The generic pieces to strip are listed in
[Preparing the zip from this repo](../../docs/submission.md#preparing-the-zip-from-this-repo).
In this plugin they are:

- the four dev lines at the top of `main.lua` (`local tee = require("dev/tee")`,
  `local remote = require("dev/remote")`, `if tee then tee.install(...) end` and
  `if remote then remote.install(...) end`, with the comment above them),
- the `if remote then remote.expose(...) end` block after the state locals in `main.lua` (with
  its comment),
- the `if remote then remote.shutdown() end` and `if tee then tee.shutdown() end` lines in
  `PluginShutdown` (with their comments),
- the "Dev checkout only" comment block in the header of `main.lua`, which says the tee asks for
  `httpAccess` and that `check-submission.sh` fails until it is stripped (that script does not
  flag it, so delete it by hand), and
- `"httpAccess"` and `urls.rsdev` in `plugin.json`, leaving no `urls` and no
  `optionalPermissions`.

Do it on a copy and check it as that section describes;
`check-submission.sh` must pass before upload. The Mod.io text below ("This plugin requests no
permissions") is true only after that check passes.

## Files

Code binds each of the plugin's modules it requires to a local named after its file, camelCased
when the name has several words (`local state = require("core/state")`,
`local prettyuiInternals = require("shell/prettyui_internals")`). A `core/` module gets a `Core`
suffix when a same-named `data/` or `shell/` module is required in the same file, or the
requiring file is itself that `shell/` module (`detectCore` in `shell/detect.lua`). `data/vars.lua`
is `varRules`, as `core/vars.lua` and `shell/vars.lua` share its name.

| File | What |
|---|---|
| `main.lua` | The three views, list, settings and info, ticking and picking, and following the login and clock |
| `shell/window.lua` | The window itself: making it, collapsing it to its strip and opening it again, and saving where it is |
| `shell/strip.lua` | The collapsed strip's content: the next chore's row, which a click ticks, or a message |
| `shell/detect.lua` | Seeing shop runs, collections and machine collects done, from shop stock, machine output, the backpack and your tile |
| `shell/vars.lua` | Seeing chores done from your own game vars, ticking only on a change it sees |
| `shell/popups.lua` | Showing celebration popups one at a time, first in first out |
| `shell/rows.lua` | One chore's row in the list, settings or info view: its icon, text and tick box (and a list row's grip; an info row has no box), changed in place |
| `shell/stepper.lua` | A Shop runs line in settings: the chore's name and its "[-] N of M [+]" buttons |
| `shell/grips.lua` | Dragging a list row by its grip: the press targets over the grips, the drag and the drop |
| `shell/prettyui_internals.lua` | Keeping the window's scroll, wheel, grips and resize cursors working across PrettyUI versions |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `core/period.lua` | When each reset period began, and the RuneDay (pure arithmetic on epoch minutes) |
| `core/state.lua` | Picks, ticks, shop purchases and shops-needed counts, and whether a chore is done now |
| `core/detect.lua` | Spotting a purchase in a shop's counts, and notes rising near a giver |
| `core/vars.lua` | Whether a chore's var rule holds on a set of var values |
| `core/view.lua` | What the list, the collapsed strip and the settings groups show, as plain data |
| `core/info.lua` | What the info view shows: the help, and each chore's status (Automatic, Unproven or Manual) from the data files' `proven` flags |
| `core/fit.lua` | Cutting a row's name short with "..." so it fits before the tick box, and breaking the help into lines |
| `core/layout.lua` | The saved window layout, read back and kept on screen, and where the collapsed strip goes |
| `core/listlayout.lua` | Where the list's, settings' and info view's headings, subheadings and rows go in the window |
| `core/reorder.lua` | Where a dragged row and its neighbours go, and when the list scrolls under a drag |
| `core/celebrate.lua` | Which celebrations a change to the picks and ticks earns |
| `core/settings.lua` | The celebration settings, defaults and reading them back |
| `data/chores.lua` | The chore list, in settings order, and its naming rules (hand-written) |
| `data/shops.lua` | The shops each shop-run chore watches (hand-written) |
| `data/collections.lua` | Who each collection chore is collected from, where, and their notes (hand-written) |
| `data/vars.lua` | The chores seen from game vars and each one's rule (hand-written) |
| `data/machines.lua` | The machine chores and the output inventories collecting empties (hand-written) |
| `data/icons.lua` | Each chore's icon, a built-in item or interface sprite (hand-written) |

The tests are in `tests/chore-tracker/` and run against the repo's mock of the plugin API
(`docs/testing.md`).

## Mod.io summary

The Profile's Summary field (shown under the screenshot on the list page; 10-250 ASCII
characters):

```text
Track your daily, weekly and monthly RS3 chores in one window. Pick the ones you do and tick them off; shop runs and many more tick themselves.
```

## Mod.io description

```markdown
Chore Tracker is a checklist for RuneScape's repeatable chores: the daily, weekly and monthly tasks such as the Daily Challenge, Soul Reaper or the Giant Oyster.

Pick the chores you do with the settings button, then click a chore in the list to tick it off. Ticks clear themselves at the game's resets, in UTC: daily chores at 00:00, weekly ones on Wednesday and monthly ones on the 1st. Drag a chore by its grip to put your list in your own order.

Some chores tick themselves: the shop runs when you buy from their shops, Dell Monti's and the Weird Old Man's when their notes arrive in your backpack, the Invention machines when you collect from one, and others, such as the Daily Challenge and Bert's sand, when the game's own record of your progress shows them done. Only a change seen while the plugin runs ticks a chore, so a chore done while it was off needs a tick by hand. The info button in the plugin lists every chore as Automatic, Unproven (should tick itself, not yet checked in game) or Manual.

The menu button at the window's top-right corner folds it into a small strip showing your next chore, which a click ticks. When the plugin ticks a chore, or you finish a period's chores, a short popup celebrates it; settings turn the popups or their sound off.

Your chores are saved per character, so each character has its own list.

## Email
The contact email address for this plugin is you@example.com.

## EULA
By submitting a Plugin (as defined in Schedule 4 of the EULA), you acknowledge that you agree to the terms of the Jagex End User License Agreement (EULA) found at https://legal.jagex.com/docs/terms/eula (and all terms incorporated into it be reference) and acknowledge that such terms are legally binding on you. If you do not agree to the terms of the EULA, you must not submit a Plugin or use the Plugin functionality anyway. In such circumstances, Jagex does not licence the software to you, or grant you any of the relevant rights relating to the submission of Plugins set out in the EULA and you will not be permitted to access or use the Plugin functionality in any way whatsoever.

## Permissions
This plugin requests no permissions.

## Data Protection
This plugin uses the following information: the game clock, your own character's display name and position, the contents of your backpack, the stock of a shop you have open, what your Invention machines hold, your own character's game vars for the chores it ticks from them, such as the Daily Challenge and Bert's sand (to see them done), and the chores you pick and tick. It shows popups about those chores, using the game's own sounds and sprites, and each chore with one of the game's own item icons or sprites.
This information is not transmitted outside of the plugin under any circumstances.
Your picked chores in your order, the ones you ticked, and when you last bought from each watched shop, and how many shops each shop run needs (when you set fewer than all), are stored on this device in the plugin's PersistentDB, under your character's display name, with the window's position, size and collapsed state. Your choices of whether to show celebration popups and play their sound are stored in the same way, for all characters.
```
