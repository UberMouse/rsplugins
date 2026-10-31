# Chore Tracker

A checklist for RuneScape's repeatable chores: the daily, weekly and monthly tasks such as the
Daily Challenge, Soul Reaper or the Giant Oyster. Pick the ones you do, tick them off as you go,
and they clear themselves at the game's reset. Many chores also tick themselves: shop runs when
you buy from their shops, Dell Monti's and the Weird Old Man's goods when their notes arrive,
Invention machines when you collect from them, and others, such as the Daily Challenge and
Bert's sand, when the game's own record of your progress shows them done. It only reads what the
game already gives your client, never does anything in game for you, and sends nothing anywhere.

## Using it

- **Opening it.** Enable the plugin and a window titled **Chores** opens. On the first run it
  says no chores are picked yet. Until the game clock is available (just after logging in), the
  window shows "Waiting for the game clock" and chores can't be ticked.
- **Picking chores.** Click the settings button at the top left of the window. Above the chores
  are a Celebrations section and a How many to do section (see below). Every chore is listed
  under Daily, Weekly and Monthly, and within Daily and Weekly under a gold subheading for its
  kind: Activities, Combat, Skilling, Upkeep, Free supplies (handed out by someone who is no
  shop) and Shops, each in alphabetical order. Monthly has too few chores to need them. Each is
  a row with its icon, its name and a tick box: click anywhere on a row to pick it (the box
  ticks) or click again to drop it. Changes save straight away. To return to your list, click
  the back button in the window's top-right corner, where the menu button usually sits. It
  stays there however far down you have scrolled. (Collapse the window from the list, not from
  here.)
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
  (the mouse button is already held for the drag) and shrinks back over the grip as soon as the
  button is released or the drag otherwise ends. A click on the grip ticks nothing; click the
  rest of the row for that. A chore you pick later goes to the end of its period.
- **Long names.** A name too long for the window is shortened with "..." so it stops before
  the tick box; make the window wider and more of it shows. Hover a shortened row and its
  tooltip starts with the full name.
- **Details.** Hover a chore for its description and its RuneScape Wiki links. The links are
  shown as text, because plugins can't open web pages.
- **Collapsing it.** The menu button at the top-right corner of the window, where a close
  button usually sits, folds the window into a small strip with that button at the same spot.
  The strip shows your next chore not yet done, as "Daily: Herb Run (3/8)": the first unticked
  one in your Daily order, or once those are all done the first in Weekly, then Monthly. Click
  it to tick that chore, as you would its row in the list, and the strip moves on to the next.
  With nothing left it says "All chores done" (or "No chores picked"). The strip is as wide as
  the longest of your picked chores, so it keeps its size while you work through them. It shows
  no tooltip. Click the menu button to open the window again: it opens leftwards and down from
  the button.
- **Info.** The info button, beside the settings button, opens a short help on the ideas
  above, then every chore under one of three headings, each with its count: **Automatic**
  (ticks itself, checked in game), **Unproven** (should tick itself, not yet checked in game)
  and **Manual** (tick it by hand). Each row shows the chore's icon and name, with its period
  after a name offered in two periods ("Dream of Iaia XP (weekly)"); hover one for the same
  tooltip as in settings. The rows can't be clicked. The back button in the window's top-right
  corner returns to the list.
- **Moving it.** Drag the window by its title bar, and resize it from its edges or corners,
  which show a resize cursor when you hover them. While it is collapsed, hold **Alt** and drag
  the strip to move it. Alt-dragging only works with the console closed.
- **Celebrations.** When a chore you picked gets ticked, whether by you (by hand, or by lowering
  its count under **How many to do**) or by the plugin, a small popup, "CHORE COMPLETE" with the
  chore's name, shows upper-middle of the screen with a short jingle. When your picked chores
  of a period are all done, a bigger one follows with a grander jingle: "DAILIES COMPLETE",
  "WEEKLIES COMPLETE" or "MONTHLIES COMPLETE". It shows again whenever they become all done.
  Unticking, picking or unpicking chores, and logging in, show nothing. Popups appear one at a
  time and last about four seconds, whether the window is open, collapsed or in settings. A
  popup already showing or waiting isn't queued again, so ticking, unticking and re-ticking a
  chore while its popup is showing or waiting shows it once. In the settings view, under
  **Celebrations**, untick "Celebration popups" to turn them off, or "Popup sound" to keep
  them quiet. Both are saved for all characters.

## Chores it ticks for you

Ticking by hand still works for every chore, these included: a chore ticked either way stays
ticked until its reset, and unticking one by hand changes nothing below.

- **Shop runs.** Buy anything at one of a chore's shops and the plugin records that shop as
  bought from this period, whether or not you picked the chore, so picking it later shows the
  period's truth. The plugin can tell because the game only sends a shop's stock while that
  shop is open, and the stock is yours alone: a line that goes down is you buying. A restock or
  something you sell to the shop doesn't count, though if you sell a shop more of an item than
  it normally stocks and keep the shop open, that stock drifting back down can look like a
  purchase. A chore with one shop ticks itself on a purchase there. A chore with more than one
  ticks once you have bought from as many of its shops as it needs this period (see **How many
  to do**). A shop the game has in two versions, before and after a quest, counts once, bought
  from either.
- **Chores done at several places.** Some chores have parts you may do all or only some of: a
  shop run's shops, the herb patches, bloodwood trees, farm troughs, the week's penguins, the
  port's voyages, Thalmund's slots and the Shattered Worlds challenges. The plugin records each
  part as you do it and ticks the chore once enough are done (see **How many to do**). The row
  shows the progress, as "Herb Run (3/8)" (never more than it needs), and so does its tooltip;
  a shop run's tooltip also lists each shop as "bought" or "not yet". Other parts aren't named,
  as the game's records don't say which patch or penguin is which.
- **How many to do.** In the settings view, under **How many to do** (below Celebrations),
  each chore you picked that has more than one part has a line with its name and
  "[-] 8 of 11 [+]": click the minus or plus to set how many of its parts tick it, from 1 to
  all of them. Hover the name for what it counts, such as "How many pens you feed, the
  breeding pen included each day." for the Player-Owned Farm. Picking or unpicking such a
  chore adds or drops its line; with none picked, the block says what it is for. A shop run
  starts at all its shops, Thalmund's Wares at all four slots and Shattered Worlds at all three
  challenges; the others start where most players are: 8 of the 11 herb patches, 1 of the 8
  bloodwood trees, 1 of the 7 farm troughs and 10 of the 13 penguins (the polar bear counts as
  one). The Player-Owned Port has no line: it always needs all 4 voyages. A count saves
  straight away and is kept per character, as characters reach different places. Lowering it
  to what you have already done this period ticks the chore (and shows its popup); raising it
  above that never unticks it.
- **Collecting from Dell Monti and the Weird Old Man.** Their goods arrive as banknotes in
  your backpack with no shop open, so the chore ticks when those notes go up in your backpack
  while you are within 10 tiles of the giver, on the same floor: Dell Monti's apple or
  pineapple notes, or the Weird Old Man's potato cactus notes (outside the Kalphite Lair;
  *unproven*, as nobody has checked his yet). Any rise counts, wherever the notes came from:
  taking some out of the bank, a trade or picking them up near the giver ticks the chore too.
- **Collecting from your Invention machines** (daily and weekly). Each Invention Guild machine
  keeps what it made in a store the game sends your client wherever you are, and only
  collecting takes from it, so the chore ticks when any machine's store goes down. Filling a
  machine doesn't count.
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
  | Crystal Tree Blossom (*unproven*) | the game records a new blossom date |
  | Sinkholes (*unproven*) | you have played two sinkholes today |
  | Big Chinchompa (*unproven*) | the game marks today's Big Chinchompa game played |
  | Fixate Charges (*unproven*) | you have used three fixate charges today |
  | Runesphere (*unproven*) | the game marks today's dust handed in |
  | Soul Reaper (*unproven*) | the game marks the week's Soul Reaper cap reached |
  | Thalmund's Wares (*unproven*) | you have bought each of Thalmund's four slots up to its limit: each slot is a part, all four by default |
  | Tears of Guthix (*unproven*) | the game marks the week's tears collected (the game may not send this one, so it may never tick) |
  | Herby Werby (*unproven*) | the game marks the week's Herby Werby completed |
  | Wisps of the Grove (*unproven*) | the game marks the week's Wisps of the Grove completed |
  | Shattered Worlds (*unproven*) | the game marks each of the week's reward challenges (bronze, silver and gold) complete: each is a part, all three by default |
  | Aquarium Treasure Chest (*unproven*) | the game marks your aquarium's treasure chest used |
  | Agoroth (*unproven*) | you have defeated Agoroth twice this week |
  | Broken Home Replay (*unproven*) | the game marks the week's Broken Home replay completed |
  | Soul Supplies from Lupe (*unproven*) | the game marks Lupe's supplies claimed |
  | Effigy Incubator (*unproven*) | the game marks the month's Effigy Incubator completed |
  | Archaeology Research | you send out a research team |
  | Miscellania (daily and weekly) | you collect the kingdom's resources |
  | Bakriminel Bolts | you fell your bloodwood trees: each tree is a part, 1 by default |
  | Player-Owned Farm | you put food in the farm's troughs: each trough is a part, 1 by default |
  | Herb Run | you plant your herb patches: each patch is a part, 8 by default |
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
  | Penguin Hide and Seek | you spot the week's penguins or the polar bear: each is a part, 10 by default |
  | Player-Owned Port | you send ships on all 4 voyages (each voyage slot is a part), or buy the Black Marketeer's offer, which ticks it by itself (the market part is *unproven*) |
  | Fort Forinthry Bonus XP | any skill's bonus XP goes up while you stand within 10 tiles of Aster, in the Town Hall: claiming from Aster does that (so does a lamp or star used beside her) |
  | Dream of Iaia Resources (daily and weekly) | every base-camp resource you have workers on has been used down to 0, and one of them just fell (sending the workers elsewhere doesn't tick it) |
  | Dream of Iaia XP (weekly and monthly) | every skilling station you have workers for holds 0 stored XP, and one just fell (sending the workers elsewhere doesn't tick it) |

  The free supplies from Bert, Geoffrey, Cromperty, Coeden and Rosie can be claimed daily in
  game, but keep the weekly reset the list gives them: one claim ticks each until Wednesday.
  Lupe's supplies are weekly here too.

  How often the two Dream of Iaia chores are due depends on how you split your workers, so
  each is offered in two periods: pick the one that fits.

  *Unproven* ones haven't been checked in game yet: their rules are inferred from the names
  the game gives its vars. The rest were checked in game.

  **Only a change the plugin sees ticks a chore.** For 10 seconds after you log in or the
  plugin starts, while the game sends your vars, no chore in this table ticks. So a chore done
  while the plugin was off, or already done when you log in, isn't ticked: tick it by hand. The
  window never shows a var's value.

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

Everything is kept on this computer in the plugin's PersistentDB.

- **Per character**, under your character's display name, so each character has its own list,
  saved as soon as it changes:
  your picked chores in your order; when each chore was last ticked, by you or by the
  plugin; when each part of a chore with several parts was last done (each shop of a shop run,
  herb patch, bloodwood tree, farm trough, penguin, port voyage, Thalmund slot and Shattered
  Worlds challenge), for every such chore whether you picked it or not; and any count you
  changed under **How many to do**. While you are logged out the window says "Log in to see
  your chores".
- **For all characters**: the window's position, size and collapsed state, and where the
  collapsed strip is, saved within a second of the window coming to rest and restored next
  time, moved back on screen if they no longer fit; and whether celebration popups and their
  sound are on.

Your position in the game is read only to tell a collection or bonus XP claim made beside Dell
Monti, the Weird Old Man or Aster from one made elsewhere. It is never stored.

## Requirements

- **PrettyUI** (mod.io 6398181), the interface library the window is built with. It is a
  required dependency: install it too.
- **No permissions.** The plugin reads the game clock, your own character's display name and
  position, your backpack, the stock of an open shop it watches, your Invention machines'
  output, and your own character's game vars for the chores in the "Seen from game vars" table.
  Plugins can read all of these without one.

## Credits

The chore list (names, descriptions, wiki links and reset periods) started as a copy of
[dailyscape](https://github.com/dailyscape/dailyscape.github.io)'s, used under its MIT licence,
and is now kept by hand in edited form. `data/chores.lua` holds it and the licence text.

## Console lines

Every line the plugin logs starts with `[CHORES]`; it never logs your display name. Grep regex
for all of them: `\[CHORES\]`. For the lines about chores it ticks or celebrates:
`\[CHORES\] (purchase|collected|seen|celebrate)`.

| Line | When |
|---|---|
| `[CHORES] loaded <n> chores` | The plugin starts |
| `[CHORES] showing the logged-in character's chores` | A character logs in, or another one does |
| `[CHORES] logged out` | You log out |
| `[CHORES] waiting for the game clock` | The window waits for the game clock after logging in |
| `[CHORES] purchase <chore id> at <shop>` | The period's first purchase at one of a chore's shops, ticking the chore or not, such as `purchase feather-shop-run at Gerrant, Port Sarim` |
| `[CHORES] collected <chore id> near <giver>` | Notes rising near a giver tick its chore, such as `collected oldman-potato-cactus near the Weird Old Man` |
| `[CHORES] collected <chore id> from <inventory>` | A collect from an Invention machine ticks its chore, such as `collected invention-machine from INVENT_MACHINE_GUILD_3_OUTPUT` |
| `[CHORES] seen <chore id> done (<var>)` | A change to the named var ticks the chore, such as `seen bert-sand done (HANDSAND_BUCKETS_CLAIMED_TODAY)` |
| `[CHORES] seen <chore id> part (<var>)` | A change to the named var records a part done that doesn't yet tick its chore |
| `[CHORES] celebrate <chore id>` | A chore's celebration popup shows |
| `[CHORES] celebrate <period> cleared` | A period's celebration popup shows, such as `celebrate daily cleared` |
| `[CHORES] moved <chore id> to <n> in <period>` | A chore is dragged to a new place, `<n>` its place in the period from 1 |
| `[CHORES] needed <chore id> <n>` | A chore's count under How many to do is changed to `<n>` |
| `[CHORES] collapsed at <x> <y>` | The window is folded into its strip, the menu button at `<x>`, `<y>` |
| `[CHORES] expanded from <x> <y>` | The strip is opened back into the window, from the menu button at `<x>`, `<y>` |
| `[CHORES] unknown var <name>; not watched` | At start, for a watched var the game no longer has; its chores are left to tick by hand |
| `[CHORES] unknown inventory <name>; not watched` | At start, for a shop's or machine's inventory the game no longer has; it ticks nothing |
| `[CHORES] unknown obj <name>; not watched` | At start, for a giver's note the game no longer has; it ticks nothing |
| `[CHORES] unknown icon id.Obj.<name>; its rows show no icon` (or `id.Sprite.<name>`) | Once, when a row first needs an icon the game no longer has |
| `[CHORES] cannot measure text with the client font; names stay unshortened: <error>` | Once, if the client can't measure text, so long names aren't cut short with "..." |

## Files

Code binds each of the plugin's modules it requires to a local named after its file, camelCased
when the name has several words (`local prettyuiInternals = require("shell/prettyui_internals")`).
A `core/` module gets a `Core` suffix when a same-named `data/` or `shell/` module is required in
the same file, or the requiring file is itself that `shell/` module (`detectCore` in
`shell/detect.lua`). `data/vars.lua` is `varRules`, as
`core/vars.lua` and `shell/vars.lua` share its name.

| File | What |
|---|---|
| `main.lua` | The three views, list, settings and info, ticking and picking, and following the login and clock |
| `shell/window.lua` | The window itself: making it, collapsing it to its strip and opening it again, and saving where it is |
| `shell/strip.lua` | The collapsed strip's content: the next chore's row, which a click ticks, or a message |
| `shell/detect.lua` | Seeing shop runs, collections and machine collects done, from shop stock, machine output, the backpack and your tile |
| `shell/vars.lua` | Seeing chores done from your own game vars, ticking only on a change it sees |
| `shell/popups.lua` | Showing celebration popups one at a time, first in first out |
| `shell/rows.lua` | One chore's row in the list, settings or info view: its icon, text and tick box (and a list row's grip; an info row has no box), changed in place |
| `shell/stepper.lua` | A How many to do line in settings: the chore's name, with its tooltip, and its "[-] N of M [+]" buttons |
| `shell/grips.lua` | Dragging a list row by its grip: the press targets over the grips, the drag and the drop |
| `shell/prettyui_internals.lua` | Keeping the window's grips and resize cursors working across PrettyUI versions: the one file that uses PrettyUI's private internals |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `shell/say.lua` | The console logger every module uses, which tags each line [CHORES] |
| `core/period.lua` | When each reset period began (pure arithmetic on epoch minutes) |
| `core/state.lua` | Picks, ticks, parts done and needed counts, and whether a chore is done now |
| `core/parts.lua` | Each chore's parts (shops, herb patches, penguins...), built from the data files |
| `core/detect.lua` | Spotting a purchase in a shop's counts, and notes rising near a giver |
| `core/vars.lua` | Whether a chore's var rule holds on a set of var values |
| `core/view.lua` | What the list, the collapsed strip and the settings groups show, as plain data |
| `core/info.lua` | What the info view shows: the help, and each chore's status (Automatic, Unproven or Manual) from the data files' `proven` flags |
| `core/fit.lua` | Cutting a row's name short with "..." so it fits before the tick box, and breaking the help into lines |
| `core/layout.lua` | The saved window layout, read back and kept on screen, where the collapsed strip goes, and the width a view's help is wrapped to |
| `core/listlayout.lua` | Where the list's, settings' and info view's headings, subheadings and rows go in the window |
| `core/reorder.lua` | Where a dragged row and its neighbours go, and when the list scrolls under a drag |
| `core/celebrate.lua` | Which celebrations a change to the picks and ticks earns |
| `core/settings.lua` | The celebration settings, defaults and reading them back |
| `data/chores.lua` | The chore list, in settings order, and its naming rules (hand-written) |
| `data/shops.lua` | The shops each shop-run chore watches (hand-written) |
| `data/collections.lua` | Who each collection chore is collected from, where, and their notes (hand-written) |
| `data/vars.lua` | The chores seen from game vars and each one's rule (hand-written) |
| `data/machines.lua` | The machine chores and the output inventories collecting empties (hand-written) |
| `data/counts.lua` | The chores done at several parts that aren't shops: their parts' word, default count and settings tooltip (hand-written) |
| `data/icons.lua` | Each chore's icon, a built-in item or interface sprite (hand-written) |

The development repo has tests for these modules, run against a mock of the plugin API.
