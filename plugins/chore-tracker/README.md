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
- **Picking chores.** Click the settings button at the top left of the window. Every chore is
  listed under Daily, Weekly and Monthly; ones that are bought from a shop end in "(shop)".
  Tick the ones you want to track: changes save straight away. To return to your list, click
  the back button in the window's top-right corner, where the menu button usually sits. It
  stays there however far down you have scrolled. (Collapse the window from the list, not from
  here.)
- **Ticking chores.** The list shows the chores you picked under Daily, Weekly and Monthly
  headings, each with a count such as "Daily  2/5". Tick a chore when you've done it. It stays
  where it is, ticked and dimmed; click it again to untick it.
- **Details.** Hover a chore for its description and its RuneScape Wiki links. The links are
  shown as text, because plugins can't open web pages.
- **Collapsing it.** The menu button at the top-right corner of the window, where
  a close button usually sits, folds the window into just that button, at the same spot. Click
  the button to open the window again: it opens leftwards and down from the button.
- **Moving it.** Drag the window by its title bar, and resize it from its edges or corners.
  While it is collapsed, hold **Alt** and drag the button to move it. Alt-dragging only works
  with the console closed.

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
  from either. When a count changes the window redraws, keeping how far it is scrolled.
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
  | Daily Challenge | you finish the last challenge you were given: your count of finished challenges rises to the number of challenge slots filled |
  | Advance Time (*unproven*) | the spell's last charge of the week is used |
  | Divine Locations (*unproven*) | you have gathered the day's limit from divine locations |

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

- **Your picks and ticks, per character.** They are saved each time you change them, under your
  character's display name, so each character on the same computer has its own list. While you
  are logged out the window says "Log in to see your chores".
- **Where the window is**, for all characters: its position, its size, whether it is collapsed,
  and where the collapsed button is. These are saved within a second of a change and restored
  next time, moved back on screen if they no longer fit.
- Until the game clock is available (just after logging in), the window shows "Waiting for the
  game clock" and chores can't be ticked.

## Requirements

- **PrettyUI** (mod.io 6398181), the interface library the window is built with. It is a
  required dependency: install it too.
- **No permissions.** The plugin reads the game clock, your own character's display name and
  position, your backpack, the stock of an open shop it watches, and the few game vars of your
  own character listed above. Plugins can read all of these without one.

## Credits

The chore list (names, descriptions, wiki links and reset periods) comes from
[dailyscape](https://github.com/dailyscape/dailyscape.github.io), used under its MIT licence.
`data/chores.lua` holds the copy, the licence text, and how to regenerate it.

## Console lines

Everything the plugin logs carries the tag `[CHORES]`: loading, collapsing and expanding,
character changes and waiting for the clock. It never logs your display name. Grep regex:
`\[CHORES\]`.

A purchase that ticks a chore, or is the period's first at that shop, logs
`[CHORES] purchase <chore id> at <shop>` (such as
`[CHORES] purchase feather-shop-run at Gerrant, Port Sarim`), and a collection that ticks its
chore logs `[CHORES] collected <chore id> near <giver>` (such as
`[CHORES] collected oldman-potato-cactus near the Weird Old Man`), and a chore ticked from
the game's vars logs `[CHORES] seen <chore id> done (<var>)`, naming the var whose change
ticked it (such as `[CHORES] seen bert-sand done (HANDSAND_BUCKETS_CLAIMED_TODAY)`). A watched
var the game no longer has is logged once at start as `[CHORES] unknown var <name>; not
watched`, and its chores are left to tick by hand. Grep regex:
`\[CHORES\] (purchase|collected|seen)`.

## Files

| File | What |
|---|---|
| `main.lua` | The window, its collapsed button, the two views, and following the login and clock |
| `shell/detect.lua` | Seeing shop runs and collections done, from shop stock, the backpack and your tile |
| `shell/vars.lua` | Seeing chores done from your own game vars, ticking only on a change it sees |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `core/period.lua` | When each reset period began (pure arithmetic on epoch minutes) |
| `core/state.lua` | Picks, ticks and shop purchases, and whether a chore is done now |
| `core/shops.lua` | Spotting a purchase in a shop's counts, and notes rising near a giver |
| `core/vars.lua` | Whether a chore's var rule holds on a set of var values, and the RuneDay |
| `core/view.lua` | What the list shows, as plain data |
| `core/layout.lua` | The saved window layout, read back and kept on screen |
| `data/chores.lua` | The dailyscape chore list (generated) |
| `data/shops.lua` | The shops each shop-run chore watches (hand-written) |
| `data/collections.lua` | Who each collection chore is collected from, where, and their notes (hand-written) |
| `data/vars.lua` | The chores seen from game vars and each one's rule (hand-written) |

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
This plugin uses the following information: the game clock, your own character's display name and position, the contents of your backpack, the stock of a shop you have open, a few of your own character's game vars (to see some chores done), and the chores you pick and tick.
This information is not transmitted outside of the plugin under any circumstances.
Your picked and ticked chores, and when you last bought from each watched shop, are stored on this device in the plugin's PersistentDB, under your character's display name, with the window's position, size and collapsed state.
```
