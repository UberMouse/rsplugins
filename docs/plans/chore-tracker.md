# Chore Tracker: where it stands and what's left

Parked on 2026-10-25. This is the plan to pick it back up from. The working state of the runs
that built it lived in the gitignored `.durable-state/`; what a later run needs from it is here.

## The ask

From the original request: a plugin tracking RS3's daily, weekly and monthly chores, where you
pick which chores show, chores tick themselves where the game makes that possible (a detection
method per class of chore), you can still tick any chore by hand, and the window is a draggable,
resizable PrettyUI window that collapses to a small hamburger button. The chore list comes from
[dailyscape](https://github.com/dailyscape/dailyscape.github.io) (MIT), keeping its wiki links.
Alongside it: a test harness that mocks the world and API (`docs/testing.md`) and a dev recorder
that dumps what a plugin sees to a local server (`lib/dev/`).

## Done

| Run | What | Commits |
|---|---|---|
| A | Test harness, dev recorder and receiver, replaying recordings as fixtures | `627db3f..209867e` |
| B | The plugin with manual ticking: chore data, resets, selection, per-character state, the window | `5581386..c0c94b0` |
| C | Shop runs tick on a purchase; Dell Monti and the Weird Old Man tick on notes gained nearby | `22f67e4..6125dd2` |
| C2 | Chores tick from the player's own game vars: 7 proven or user-accepted, 16 unproven | `6125dd2..69d3f6f` |

34 of the 67 chores tick themselves. The plugin README's "Chores it ticks for you" is the list,
and `data/shops.lua`, `data/collections.lua` and `data/vars.lua` are the source.

## Decisions that bind later work

These are the user's calls. They aren't all visible in the code.

- **Work in runs, one detection class per run.** Stage a big task: build the first visible slice,
  then stop for the user to try it in the beta client before building the rest.
- **Tick only on a change you saw happen.** A detector ticks when a signal goes from not-done to
  done while the plugin watches. It never unticks; the period reset does that. A login never
  ticks: values read in the first 10 s after load or a character switch only set the baseline.
  **Assumption:** 10 s covers the login burst of vars in the live client. It can't be checked in
  beta, where logging out disables plugins.
- **Keep dailyscape's period** even where the game's flag is daily (Bert, Geoffrey, Cromperty,
  Coeden, Lupe are weekly chores): the first claim in the week ticks it. Dream of Iaia is the
  exception (see "Round 2").
- **Shop runs:** a multi-shop chore shows a per-shop count, shop stock is per character, and any
  stock drop counts (decay left as is). Superseded 2026-10-29: "any purchase at any listed shop
  ticks it" becomes "every shop the user chose for that chore" (see "Round 2").
- **Unproven rules ship, marked.** A rule whose signal was never seen moving in the client has
  `proven = false` and the README says so. Flip it when a `[CHORES] seen <id>` line shows it
  working.
- **Daily Challenge ticks on claiming a reward** (any rise of `CHALLENGE_TOTAL_COMPLETED`), not on
  finishing a challenge.
- **Chat is an optional permission.** A chat detector must work as a fallback: the plugin runs
  without `chatAccess`, and a detector switches on when it's granted (`OptionalPermissionChanged`).
  Read only system lines (empty sender), never player chat. Requesting a permission puts the
  plugin in the extra-review tier, so the Mod.io listing must justify it.
- **Never show a var's value**; vars only tick chores. The README's Data Protection section names
  what the plugin reads without counting the vars.
- **Off limits:**
  - `GODSS_PLAYER` is another player's id. Never read it.
  - Black Marketeer `POP_MARKET_RESOURCE_ROLLS` may encode upcoming offers. Never read it.
  - The penguin vars (`PENG_SPY_*`) may encode this week's locations. Don't use them without
    the user's go-ahead.
- **PrettyUI has no licence:** read its source locally, never copy or vendor it. The window's
  scroll keep and the drag grips read PrettyUI 1.2.0's internal `_scroll.scrollY`, each list
  row is handed the window's internal `_onScrollWheel` so the wheel scrolls over it, and the
  grips' press targets are placed from the window's `viewport` (all guarded); the user may veto
  any of them.

## Round 2: making the list nicer (decided 2026-10-29)

The user's ideas from 2026-10-29, the calls they made, and what research found. Steps 1 and 2
are built and user-checked in the client (step 2's ticked-box hover aside); step 3 is built, not
yet checked in the client; the rest is not. Staged order, with a check-in in the beta client
after each:

1. **Celebration popup** (built `280a68a..c1b5a76`; `core/celebrate.lua`, `shell/popups.lua`).
   The user checked it in the client on 2026-10-29: the auto-tick popup, the period-clear popup
   from a hand tick and again after an untick and re-tick, and both settings toggles. **Not yet
   heard:** the sounds (`ARCH_INFO_POPUP`, `LEAGUE2_HARD_TASK_COMPLETE`), as the user's VM has no
   audio; check them on a machine with sound. On a tick the plugin made itself (not a manual
   click), show
   `prettyui.AchievementPopup.show{title, text, item, x, y, xAnchor, yAnchor, sound, soundID}`
   centred, a third of the way down. On clearing a whole period, show a bigger one with a grander
   jingle. PrettyUI 1.2.0 exports it: a HUD-framed toast with an item slot that fades out after
   about 4 s, and its default sound is `id.Sound.ARCH_INFO_POPUP`. Built-in jingles to pick from
   are `LEAGUE2_{EASY,MEDIUM,HARD,ELITE,MASTER}_TASK_COMPLETE` and
   `CHEEVO_ACHIEVEMENT_COMPLETE_SOUND_V3` (`docs/api/consts/Sound.lua`). `audio.Play` takes a
   built-in id, so no custom sound ships. Probe: the popup anchors and draws over the game view.
2. **Own row component with an item icon.** PrettyUI's `CheckboxButton` takes no icon and can't
   be dragged, so build a row from `ui.Layer` + `ui.Sprite` (`SetAssociatedObject(objId)` draws
   the item's built-in icon) + text + a tick sprite. Icons come from a hand-written
   `data/icons.lua` (chore id -> an `id.Obj` or `id.Sprite` constant name, checked against
   `docs/api/consts/` by `tests/chore-tracker/data_spec.lua`). Built for the list view
   (`d2380ef..9b8cb29`: `shell/rows.lua`, `core/listlayout.lua`, `core/fit.lua`) and
   user-checked in the client 2026-10-29: icons, a click anywhere on a row ticks it, tooltips,
   and long names cut with "..." before the box and re-fitted on resize (the tooltip then leads
   with the full name). The user's calls: 24 px icons in 28 px rows; an XP reward shows the XP
   coin or the skill's medallion sprite, a lamp the lamp, a general shop the General Store map
   icon. The settings view's picks followed (`47df67d..6934fda`; settings rows user-checked
   2026-10-29): the same icon rows, ticked when picked and never dimmed. Every row, in both
   views, shows `CURSOR_HYPERLINK_HAND` (the user's pick from a cursor probe) and a hovered box
   from the four-state `RS3_BTN_CHECKBOX_0..3` set, so a ticked box reacts to hover too (that
   last part not yet checked in the client). Use built-in sprites only, because a custom PNG
   puts the plugin in closer review. Probed 2026-10-29
   (`docs/api-concepts.md`, "Pointer hooks on a plain `ui.Layer`" and "Hand-built rows in a
   window"): icons draw and clip in the window, and dimmed icon plus ticked box reads as done.
   A row must forward the wheel to the window itself. Act on `ONCLICK`, since a fast click
   arrives release-first. The native drag hooks never fire, so step 3 builds its drag from
   press, hold, release and the mouse position.
3. **Reorder by drag, within each period.** Built (run R3: `5421b8c..db53909` the pure core,
   `1470cee..63ea43a` the harness's press/hold/release driver, then the grip and drag), not yet
   checked in the client. The order is the player's own, saved per character in
   `state.selected`; a newly picked chore goes to the end of its period. The user's calls: a
   grip at the row's left (`id.Sprite.HAMBURGER_MENU_ICON` 8122, 16 px) so a click anywhere
   else still ticks; the grip's cursor `id.Cursor.CURSOR_PUSH` 196, over the grip and for the
   whole drag (both picked in probes, docs/api-concepts.md); live shift (the row follows the
   pointer, the period's other rows slide apart); auto-scroll past the list's edges; one press
   target per visible grip. The client's `ONDRAG` hooks never fired, and the drag probes v1-v3
   (docs/api-concepts.md, "Pressing and dragging a plain `ui.Layer`") showed a press ends once
   the pointer leaves the pressed layer's rect clipped by its ancestors, so a row inside the
   window can't carry a drag. So `shell/grips.lua` puts an invisible press target on the plugin
   layer over each grip, re-docked every Logic tick from the window's `viewport` and
   `_scroll.scrollY` (a dev-bridge probe showed `xyGlobal` leaves out an ancestor's scroll), and
   on its first `ONHOLD` stretches it over the plugin layer and brings it to the front, the v3
   pattern (PrettyUI 1.2.0's scroll-thumb drag). `core/reorder.lua` gives the slot and the rows'
   spots; the drop calls `state.move` and saves once. The settings view has no grips. If the
   drag proves unreliable in the client, the fallback is up/down buttons in settings.
4. **Per-chore settings.**
   - **Shop runs:** the user picks which of a chore's shops they visit, and it ticks once every
     chosen shop has been bought from this period. The default is all listed shops.
   - **Dream of Iaia:** merge dailyscape's two rows (resources weekly, XP monthly) into one chore
     with a manual cadence setting (every 1/2/3 days, weekly, fortnightly). The wiki
     (Dream_of_Iaia, read 2026-10-29) gives no fixed reset. Stations cap at 350k stored XP and
     resources at 150k (with a level 3 Town Hall), and the cadence follows the worker split via
     Giles: all workers on one resource is about every 36 h for resources and 7 days for XP, and
     a two-way split is about 72 h and 14 days. Later, "due when near the cap" from game data:
     candidates are `DINO_BASE_CAMP_WORKER_ASSIGNED_*`, `DINO_BASE_CAMP_RESOURCE_*`,
     `DINO_BASE_CAMP_BUILDING_TIER_TOWNHALL`, `QUEST_EGW_FINALE_REWARD_STATION_XP_*`,
     `_REWARD_STATION_STATE_*` and `_POST_QUEST_REWARD_SETUP` (3 bits, meaning unknown). Probe:
     whether these are sent away from Anachronia, and what they hold. A "stockpile" chore class
     like this might later fit the Invention machine and the Miscellania coffers too.
5. **More auto-detection**, from the table below, batched to the chores the user actually does.

## Chores still ticked by hand (33)

Each is grouped by the most promising route. "Candidates" are var names from `docs/vars/vars.csv`
or API signals. None has been seen moving. "Probe" is what a probe in the beta client must show
before building. Notes are from 2026-10-25 research.

### Var candidates: probe first, then the cheapest batch to build

| Chore | Period | Candidates | Probe must show |
|---|---|---|---|
| Archaeology Research | daily | `ARCH_RESEARCH_CONTRACT_1_STATE`, `_RESEARCH_ID`; `ARCH_RESEARCH_TOTAL_TIME` | STATE going sent -> returned; only CONTRACT_1 exists, so one team? |
| Goebie Bands | daily | `RAID1_GOEBIE_COURIER_LOOTED_TODAY`, `_LOOT_HANDED_IN_TODAY`, `_PARTICIPATED` | which counter reaches the daily cap on a Supply Run, and the cap |
| Menaphos Obelisk/Scarabs | daily | `MENAPHOS_SOUL_OBELISK_DRAINED_AMOUNT`, `MENAPHOS_SCARABS_SQUISHED_TODAY` | whether either resets daily, and its cap |
| Arc Contracts | daily | `PGC_TALLY`, `PGC_PER_DAY_INCREASE`, `PGC_GIVER_ID` | TALLY +1 per contract; the daily cap |
| Herb Run | daily | `FARMING_HERB_VARBIT_*`, `FARMING_HERB_PLANTED_n`; farming vars do transmit near a patch | the patch-state encoding; "done" = every unlocked patch replanted since reset |
| Miscellania (daily and weekly) | both | `MISC_APPROVAL`, `MISC_COFFERS`, `MISC_COFFER_CHANGE_AMOUNT`; Inv `MISC_RESOURCES_COLLECTED` | what "done" means (approval at max, coffers topped up, resources collected), then its var |
| Invention Machine (daily and weekly) | both | `INVENT_MACHINE_CHARGE`, `_AMOUNT_STORED`, `_BATCHES_STORED` (`!inventmachinerun` advances machines) | which var shows "collected and refilled" |
| Capping Clan Citadel | weekly | `CLAN_CITADEL_PLAYER_RESOURCE_*` vs `CLAN_CITADEL_RESOURCE_CAP`; `CLAN_CLAIMED_XP_REWARD` | a resource reaching the cap, or a flag setting |
| Rush of Blood | weekly | `ELFCITY_SLAYER_WEEKLY_RESET`, `_WEEKLY_CHALLENGE_LEVEL`, `_WAVES_COMPLETED` | which marks the weekly run complete |
| Water Filtration | weekly | `DUEL_ARENA_REMOVAL_WATER_FILTRATION_LOOT_TIME`, `_PREVIOUS_LOOT_TIME` | LOOT_TIME after a clean-out, and its unit |
| Arc Supplies Crate | weekly | `ELR2_FREE_SUPPLIES`, `ELR1_DAILY_SUPPLIES_TAKEN` | which moves when Rosie's crate is claimed |
| Dream of Iaia Resources | weekly | `QUEST_EGW_FINALE_REWARD_STATION_XP_*` (stored XP per station) | a weekly-limit var, if any |
| Dream of Iaia XP | monthly | the same station vars; done = all stored XP spent | stored XP falling to 0 |
| GWD2 Bounties | weekly | `GWD2_REP_TASKS_AVAILABLE`, `_TASK_PROGRESS`, `_TASK_LAST_DAY_GIVEN` | AVAILABLE counting stored bounties; done = none left? |
| Giant Oyster | monthly | `TUTISLAND_REWARD_STATE`, `_HARVEST_COUNT_*`, `_OYSTER_FED_*` | which marks this month's chest claimed |
| Troll Invasion | monthly | `DNDTRACKER_TROLL_INVASION_LIMIT` (its base var is sent) | LIMIT -> 1 after all waves |
| God Statues | monthly | `GODSS_MONTHS_SINCE_USED`, `GODSS_LAST_RESET_MONTH`; **never `GODSS_PLAYER`** | MONTHS_SINCE_USED -> 0 after building |
| Player Owned Ports | daily | Black Marketeer `POP_MARKET_QUANTITY`; **never `POP_MARKET_RESOURCE_ROLLS`** | whether buying the offer zeroes QUANTITY. Borderline: ask the user before building. "Manage port" stays manual |

### Game chat (needs the optional `chatAccess`)

| Chore | Period | Notes |
|---|---|---|
| Penguin Hide and Seek | weekly | chat is the route that avoids the penguin vars; the spotting lines are unrecorded |
| Meg | weekly | login line "You receive word that Meg has returned from her latest adventure." (wiki, not recorded) marks the reset, not the answers; `POP_MEG_CONFIDENCE` is a var candidate |
| Rapid Growth | daily | `POF_RAPID_GROWTH` holds per-patch bits but no cast count; check for a cast message |
| Familiarisation | weekly | the `DNDTRACKER_FAMILIARIZATION_*` vars are only a schedule timer |

No chore's chat line has been recorded yet. A recorder session with `chatAccess` granted, doing
each chore, comes first.

### Activity signals

| Chore | Period | Signal |
|---|---|---|
| Book of Char | daily | `SkillTransmit` Firemaking plus `MiniMenuEntrySelected` on the book |
| Bak Bolts | daily | bakriminel bolts rising in `INV` (dailyscape says every 6 h, which doesn't fit a daily reset; maybe manual) |
| Skeletal Horror | weekly | `NPCEntityRemoved` of the boss nearby (NPC tracking is the extra-review tier); its clue alone has other sources |
| Big Top Bonanza | weekly | no var found; a change log plus chat during a show |

Inventory rewards (lamps, clues) have other sources, so an item alone gives false ticks: pair
it with location or a var. There is no interface-opened event.

### Unconfirmed shop

- **Bandit Duty Free** (weekly): candidate Inv `DT_BANDIT_SHOP`. Its shop id wasn't probed
  (account state). Adding it is a `data/shops.lua` row, unproven, once the id is checked.

### Probably manual only

- **Nemi Forest**: the map comes from outside the game.
- **Player Owned Farm**: no single completion.
- **Charge Anachronia Totems**: `DINO_TOTEM_HOTSPOT_*` only. A change log while recharging
  might find more.
- **Fort Forinthry Bonus XP**: nothing specific. A change log while claiming might find a var,
  or a star or lamp arriving in `INV`.

## How to probe a var chore

1. Start the receiver: `python3 -I scripts/var-dump-receiver.py`. In the client
   console: `prf`, `pon var-dump`, `ppr var-dump`, `ppe var-dump httpAccess`
   (`plugins/var-dump/README.md`).
2. Run `python3 -I scripts/var-dump-changes.py --last-session` and note the `last seq`.
3. Do the chore in game. `!allinone` meets the requirements on a beta character
   (`docs/cheats.md`).
4. Run `python3 -I scripts/var-dump-changes.py --after <seq>`. It prints each change with the
   VarBits it moved; `--match <regex>` narrows it.
5. Relog and dump a snapshot to see whether the done state is sent at login. Reset behaviour
   needs one natural reset (daily 00:00 UTC; weekly Wednesday 00:00 UTC).

## Open in-client checks

- After a daily reset, claim a freebie (Bert's sand). If it ticks, the game's claimed-today
  flag clears daily.
- After a daily reset, claim a Daily Challenge reward. If it ticks, `CHALLENGE_TOTAL_COMPLETED`
  keeps rising across days. A second claim on 2026-10-25 took it 3 -> 4 the same day, so it isn't
  capped at 3 a day.
- The 16 unproven var rules: a `[CHORES] seen <id> done (<var>)` line proves one. Tears of
  Guthix may never tick: its base var `SHOP_MULTIPURPOSE` wasn't sent during an Arhein purchase.
- At load, no `[CHORES] unknown var` line should appear. Whether the client returns nil or raises
  for an unknown var or config name is unconfirmed; the plugin handles both.
- Console regex for all of the plugin's detection lines:
  `\[CHORES\] (purchase|collected|seen|unknown var)`.
- Drag a chore by its grip (step 3): the PUSH cursor over the grip, the rows sliding apart, a
  drag that overshoots the window and comes back, the drop kept after `prl chore-tracker`, a
  click on the row (not the grip) still ticking, and the list scrolling while dragging past its
  bottom edge. A drop logs `[CHORES] moved <chore id> to <n> in <period>`.

## Before submitting to Mod.io

- `plugin.json`'s `contactEmailAddress` is the placeholder `you@example.com`.
- Prove or drop the unproven rows: shop entries and var rules with `proven = false`.
- Ship without dev tooling: no `dev/` symlink and no `urls.recorder` (Chore Tracker has neither
  today). There is no packaging check for this yet.
- Check the README's Mod.io sections against `docs/submission.md`.

## Known gaps

- No spec covers the VarTransmit domain filter: the harness would need a var with the same id in
  another domain.
- `scripts/chores-from-dailyscape.py` raises a raw `OSError` on an unreadable input or unwritable
  output.
- `docs/testing.md`'s replay "Not applied" bullet doesn't mention out-of-range ints (real values
  don't hit it).
- The dev recorder buffers silently until `httpAccess` is granted. A probe once sent nothing and
  nothing said why; always `ppr` then `ppe <plugin> httpAccess`.
- The chat sanitiser's `[0-9,]+` slots could pass an all-digit display name, if the game allows
  one. Allowlist review must use `[0-9,]` only where the game writes a number.
- `docs/vars/vars.csv` is regenerated from a dump; rerun `scripts/var-dump-analyze.py --catalog`
  after a game update (it lacked `HALLOWEEN26_PERM_1/2` on 2026-10-25).
