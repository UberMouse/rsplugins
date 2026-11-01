# Chore Tracker

A checklist of RuneScape's daily, weekly and monthly chores, such as the Daily Challenge, Soul
Reaper and the Giant Oyster. It needs PrettyUI (mod.io 6398181), the interface library its window
is built with: install it too. It asks for no permissions.

Pick the chores you do and tick them off as you go. Ticks clear at the game's reset, and many
chores tick themselves when the plugin sees them done. It only reads what the game already gives
your client, never does anything in game for you and sends nothing anywhere.

## Using it

- **Picking chores.** Open settings with the settings button, then click a chore to pick it and
  again to drop it.
- **Ticking chores.** Click a chore's row in the list to tick it, and again to untick it.
- **Ordering chores.** Drag a row by the grip at its left to move it within its period. During a
  drag only, an invisible layer over the screen keeps the drag following the pointer. It takes no
  game input (the mouse button is already held for the drag) and shrinks back over the grip as
  soon as the button is released or the drag otherwise ends.
- **Details.** Hover a chore for its description and RuneScape Wiki links. The links are text,
  because plugins can't open web pages.
- **Collapsing.** The menu button folds the window into a strip that shows your next unticked
  chore, as "Daily: Herb Run (3/8)": the first in your Daily order, then Weekly, then Monthly.
  Click the strip to tick that chore. To move the strip, hold **Alt** and drag it. This only works
  with the console closed.
- **Info.** The info button opens a short help and lists every chore as **Automatic** (ticks
  itself, checked in game), **Unproven** (should tick itself, not yet checked in game) or
  **Manual** (tick it by hand).
- **Celebrations.** When a chore you picked gets ticked, by you or by the plugin, a "CHORE
  COMPLETE" popup with its name shows upper-middle of the screen with a short jingle. When all
  your picked chores of a period are done, a bigger popup follows with a grander jingle: "DAILIES
  COMPLETE", "WEEKLIES COMPLETE" or "MONTHLIES COMPLETE". Popups show one at a time, for about
  four seconds each. Under **Celebrations** in settings, untick **Celebration popups** to turn
  them off, or **Popup sound** to keep them quiet.

## Chores it ticks for you

Ticking by hand still works for every chore, these included.

- **Shop runs.** Buying anything at one of a chore's shops records that shop as bought from this
  period, whether or not you picked the chore. A purchase is an item's stock dropping while the
  shop is open, so a restock or something you sell to the shop doesn't count. A chore with one
  shop ticks on a purchase there. A chore with several ticks once you have bought from enough of
  them (see **How many to do**). *Unproven* shops were matched by name to the game's list of shop
  inventories, but no purchase there has been checked yet. They count the same way.

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

- **How many to do.** Some chores have parts you may do all or only some of. The plugin records
  each part as you do it and ticks the chore once enough are done. In settings, under **How many
  to do**, each picked chore with parts has a "[-] 8 of 11 [+]" line that sets how many, from 1 to
  all. Lowering it to what you have already done this period ticks the chore and shows its popup.
  Raising it never unticks it. Counts start at:

  | Chore | Each part is | Starts at |
  |---|---|---|
  | Shop runs | a shop | all |
  | Herb Run | a herb patch | 8 of 11 |
  | Bakriminel Bolts | a bloodwood tree | 1 of 8 |
  | Player-Owned Farm | a farm trough | 1 of 7 |
  | Penguin Hide and Seek | a penguin, or the polar bear | 10 of 13 |
  | Thalmund's Wares | a slot | all 4 |
  | Shattered Worlds | a reward challenge | all 3 |
  | Player-Owned Port | a voyage | all 4, with no line to change it |

- **Dell Monti and the Weird Old Man.** Their goods arrive as banknotes in your backpack, with no
  shop open. The chore ticks when those notes go up in your backpack while you are within 10
  tiles of the giver, on the same floor: Dell Monti's apple or pineapple notes, or the Weird Old
  Man's potato cactus notes (outside the Kalphite Lair; *unproven*). Any rise counts, so taking
  notes out of the bank, a trade or picking them up near the giver ticks the chore too.
- **Invention machines** (daily and weekly). The chore ticks when you collect from any Invention
  Guild machine. Filling one doesn't count.
- **Seen from game vars.** The game sends your client your own character's vars, numbered values
  that record its progress. A chore below ticks when a change to one shows the chore done.

  | Chore | Ticks when |
  |---|---|
  | Sand from Bert | Bert's sand claimed |
  | Flax from Geoffrey | Geoffrey's flax given |
  | Pure Essence from Cromperty | Cromperty's essence claimed |
  | Logs from Coeden | Coeden's logs claimed |
  | Daily Challenge | any challenge reward claimed in the challenge window, even before all three |
  | Advance Time (*unproven*) | the spell's last charge of the week used |
  | Divine Locations (*unproven*) | the day's limit gathered from divine locations |
  | Crystal Tree Blossom (*unproven*) | a new blossom date recorded |
  | Sinkholes (*unproven*) | two sinkholes played today |
  | Big Chinchompa (*unproven*) | today's game played |
  | Fixate Charges (*unproven*) | three fixate charges used today |
  | Runesphere (*unproven*) | today's dust handed in |
  | Soul Reaper (*unproven*) | the week's cap reached |
  | Thalmund's Wares (*unproven*) | each of the four slots bought up to its limit (each slot a part) |
  | Tears of Guthix (*unproven*) | the week's tears collected (the game may not send this one, so it may never tick) |
  | Herby Werby (*unproven*) | completed this week |
  | Wisps of the Grove (*unproven*) | completed this week |
  | Shattered Worlds (*unproven*) | each of the week's bronze, silver and gold reward challenges complete (each a part) |
  | Aquarium Treasure Chest (*unproven*) | your aquarium's treasure chest used |
  | Agoroth (*unproven*) | Agoroth defeated twice this week |
  | Broken Home Replay (*unproven*) | the replay completed this week |
  | Soul Supplies from Lupe (*unproven*) | Lupe's supplies claimed |
  | Effigy Incubator (*unproven*) | completed this month |
  | Archaeology Research | a research team sent out |
  | Miscellania (daily and weekly) | the kingdom's resources collected |
  | Bakriminel Bolts | your bloodwood trees felled (each tree a part) |
  | Player-Owned Farm | food put in the farm's troughs (each trough a part) |
  | Herb Run | your herb patches planted (each patch a part) |
  | God Statues | the game's count of months since you built the statues falls to 0 |
  | Troll Invasion | the month's limit reached |
  | Menaphos Obelisk and Scarabs | 23 corrupted scarabs squashed today (the last at full reputation) and the soul obelisk drained at all |
  | Goebie Supply Run | today's 10 supplies handed in |
  | GWD2 Bounties | Feng gives you a bounty |
  | Clan Citadel Cap | the quartermaster's weekly XP boost claimed |
  | Rush of Blood | a wave cleared in the week's reward run |
  | Meg's Questions | Meg leaves on her mission after your third answer |
  | Water Filtration | a new clean-out time recorded |
  | Arc Supplies from Rosie | Rosie's free supplies taken |
  | Giant Oyster | the oyster fed both its sea cucumber and its seaweed |
  | Arc Contracts | the day's last contract done: 3, plus one for each "contracts per day" upgrade bought |
  | Penguin Hide and Seek | the week's penguins or the polar bear spotted (each a part) |
  | Player-Owned Port | ships sent on all 4 voyages (each voyage slot a part), or the Black Marketeer's offer bought (*unproven*) |
  | Fort Forinthry Bonus XP | any skill's bonus XP goes up within 10 tiles of Aster, in the Town Hall: claiming from Aster does that (so does a lamp or star used beside her) |
  | Dream of Iaia Resources (daily and weekly) | every base-camp resource you have workers on used down to 0, and one of them just fell (sending the workers elsewhere doesn't tick it) |
  | Dream of Iaia XP (weekly and monthly) | every skilling station you have workers for at 0 stored XP, and one just fell (sending the workers elsewhere doesn't tick it) |

  Rosie's crate fills by five supplies a day and holds them until you take them, so the list keeps
  her weekly: one claim ticks her until Wednesday.

  How often the two Dream of Iaia chores are due depends on how you split your workers, so each
  is offered in two periods: pick the one that fits.

  *Unproven* rules are inferred from the names the game gives its vars and haven't been checked
  in game.

  **Only a change the plugin sees ticks a chore.** For 10 seconds after you log in or the plugin
  starts, while the game sends your vars, no chore in this table ticks. So a chore done while the
  plugin was off, or already done when you log in, isn't ticked: tick it by hand. The window
  never shows a var's value.

## When chores reset

By the game clock, in UTC:

- **Daily** chores at 00:00 each day.
- **Weekly** chores at 00:00 on Wednesday.
- **Monthly** chores at 00:00 on the 1st of the month.

A ticked chore unticks by itself when its reset passes, even with the window open.

## What it reads and stores

The plugin reads the game clock, your own character's display name and position, your backpack,
the stock of an open shop it watches, your Invention machines' output and your own character's
game vars for the chores in the "Seen from game vars" table. Plugins can read all of these without
a permission.

The plugin reads your position only to tell a collection or bonus XP claim made beside Dell
Monti, the Weird Old Man or Aster from one made elsewhere. It never stores your position.

It keeps everything on this computer, in the plugin's PersistentDB:

- **Per character**, under your character's display name: your picked chores in your order, when
  each chore was last ticked (by you or by the plugin), when each part of a chore with several
  parts was last done (for every such chore, picked or not) and any count you changed under **How
  many to do**.
- **For all characters**: the window's position, size and collapsed state, where the collapsed
  strip is and whether celebration popups and their sound are on.

## Credits

The chore list (names, descriptions, wiki links and reset periods) is an edited copy of
[dailyscape](https://github.com/dailyscape/dailyscape.github.io)'s, used under its MIT licence.
`data/chores.lua` holds it and the licence text.

## Console lines

Every line the plugin logs starts with `[CHORES]`, so `\[CHORES\]` matches them all. It never logs
your display name.

## Files

| File | What |
|---|---|
| `main.lua` | The list, settings and info views; ticking and picking; following the login and clock |
| `shell/window.lua` | The window: making it, collapsing it to its strip, opening it again and saving where it is |
| `shell/strip.lua` | The collapsed strip's content |
| `shell/detect.lua` | Shop runs, collections and machine collects seen done, from shop stock, machine output, the backpack and your tile |
| `shell/vars.lua` | Chores seen done from your own game vars |
| `shell/popups.lua` | Celebration popups, one at a time |
| `shell/rows.lua` | One chore's row in any view |
| `shell/stepper.lua` | A How many to do line |
| `shell/grips.lua` | Dragging a list row by its grip |
| `shell/prettyui_internals.lua` | Keeping the window's grips and resize cursors working across PrettyUI versions: the one file that uses PrettyUI's private internals |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `shell/say.lua` | The console logger, which tags each line [CHORES] |
| `core/period.lua` | When each reset period began |
| `core/state.lua` | Picks, ticks, parts done and counts |
| `core/parts.lua` | Each chore's parts, from the data files |
| `core/detect.lua` | Spotting a purchase in a shop's counts, and notes rising near a giver |
| `core/vars.lua` | Whether a chore's var rule holds |
| `core/view.lua` | What the list, strip and settings show, as plain data |
| `core/info.lua` | What the info view shows |
| `core/fit.lua` | Shortening a long name with "..." and breaking the help into lines |
| `core/layout.lua` | The saved window layout, kept on screen, and where the strip goes |
| `core/listlayout.lua` | Where each view's headings and rows go |
| `core/reorder.lua` | Where a dragged row and its neighbours go, and scrolling under a drag |
| `core/celebrate.lua` | Which celebrations a change earns |
| `core/settings.lua` | The celebration settings and their defaults |
| `data/chores.lua` | The chore list and its naming rules |
| `data/shops.lua` | Each shop run's shops |
| `data/collections.lua` | Each collection chore's giver, place and notes |
| `data/vars.lua` | The chores seen from game vars, and their rules |
| `data/machines.lua` | The machine chores and their output inventories |
| `data/counts.lua` | Parts that aren't shops: their word, default count and settings tooltip |
| `data/icons.lua` | Each chore's icon, a built-in item or interface sprite |

The `data/` files are hand-written.
