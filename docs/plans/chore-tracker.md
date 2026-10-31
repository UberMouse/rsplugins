# Chore Tracker: where it stands and what's left

Parked on 2026-10-25. This is the plan to pick it back up from. The working state of the runs
that built it lived in the gitignored `.durable-state/`; what a later run needs from it is here.

## The ask

From the original request: a plugin tracking RS3's daily, weekly and monthly chores, where you
pick which chores show, chores tick themselves where the game makes that possible (a detection
method per class of chore), you can still tick any chore by hand, and the window is a draggable,
resizable PrettyUI window that collapses to a strip showing the next chore not done. The chore list comes from
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
| D | The 30 manual chores audited: 24 now tick themselves, all seen ticking in the client; 6 confirmed manual (see below) | 2026-10-31 |

62 of the 68 chores tick themselves (41 checked in game, 21 unproven). The plugin README's "Chores it ticks for you" is the list,
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
  exception (offered in two periods each, see "Round 2").
- **Shop runs:** a multi-shop chore shows a per-shop count, shop stock is per character, and any
  stock drop counts (decay left as is). Superseded 2026-10-29: "any purchase at any listed shop
  ticks it" becomes "every shop the user chose for that chore" (see "Round 2"). That in turn was
  superseded 2026-10-31: the setting is a count, not a choice of which shops. Each chore with
  more than one listed shop ticks once that many distinct listed shops were bought from this
  period; the default is all listed shops, it is set with a stepper in settings and saved per
  character (shop access differs per character). A count change never ticks or unticks; the
  next purchase is judged by it.
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
- **Reading a var only to tick a chore is fine, hidden or not** (the user, 2026-10-31,
  superseding the earlier "off limits" list for the Black Marketeer and penguin vars): the
  plugin shows the user nothing from it. A var may still never be shown, and:
  - `GODSS_PLAYER` is another player's id. Never read it.
- **PrettyUI has no licence:** read its source locally, never copy or vendor it. The window's
  scroll keep and the drag grips read PrettyUI 1.2.0's internal `_scroll.scrollY`, each list
  row is handed the window's internal `_onScrollWheel` so the wheel scrolls over it, and the
  grips' press targets are placed from the window's `viewport` (all guarded); the user may veto
  any of them.

## Round 2: making the list nicer (decided 2026-10-29)

The user's ideas from 2026-10-29, the calls they made, and what research found. Steps 1 to 3
are built and user-checked in the client (step 2's ticked-box hover aside); the rest is not.
Staged order, with a check-in in the beta client after each:

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
   `1470cee..63ea43a` the harness's press/hold/release driver, then the grip and drag), and
   user-checked in the client 2026-10-29: the PUSH cursor over the grip, the rows sliding apart
   while dragging, a drag that overshoots the window kept, the release dropping the row, the
   order kept after `prl chore-tracker`, a click on the row ticking it while a click on the grip
   doesn't, and the list scrolling while dragging past its edge. The order is the player's own,
   saved per character in `state.selected`; a newly picked chore goes to the end of its period.
   The user's calls: a grip at the row's left (`id.Sprite.HAMBURGER_MENU_ICON` 8122, 16 px) so
   a click anywhere else still ticks; the grip's cursor `id.Cursor.CURSOR_PUSH` 196, over the grip
   and for the whole drag (both picked in probes, docs/api-concepts.md); live shift (the row follows the
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
   - **Shop runs:** built (2026-10-31) as a count, superseding "which shops": each chore with more
     than one listed shop has a "shops needed" count, 1 to its number of listed shops, default
     all of them, set with a `[-] N of M [+]` stepper under "Shop runs" in settings and saved per
     character (`ChoreState.needed`, state version 3). It ticks once that many distinct listed
     shops were bought from this period.
   - **Dream of Iaia:** replaced (2026-10-31) by per-period entries with drain detection, not a
     cadence setting. The cadence follows the worker split (all workers on one resource: about
     36 h for resources, 7 days for XP; a two-way split about 72 h and 14 days), so resources are
     offered daily and weekly and XP weekly and monthly (`dream-of-iaia-resource-daily`,
     `dream-of-iaia-xp-weekly`). Both tick when every worked resource or station has been
     drained to 0 (`any` groups and a `falls` field in the rule language). "Due when near the
     cap" is not built.
5. **More auto-detection**, from the table below, batched to the chores the user actually does.

## The manual chores, audited (2026-10-31)

The user's call: every chore that was ticked by hand is suspect. Each must get a detector,
unproven until checked, or be confirmed manual with the reason, and a detector that rsdev can
validate in the client (`!setvar`, `!getvar`, `!tele`) is automatic. Of the 30, 24 tick
themselves and each was seen ticking in the client: 21 var rules, the 2 Invention machine
chores (a new output detector, `data/machines.lua`) and Bandit Duty Free (a shop row). 6 stay
manual, each for a reason below. Status counts now: 41 automatic, 21 unproven, 6 manual.

**How each rule was validated** (session `a3abc00dce`): `!getvar` read each var's value, then
`!setvar` moved it to a done value, the console showed `[CHORES] seen <id> done (<var>)`, and
a second `!setvar` put the old value back. The two `!setvar`s need about 3 s between them: sent
back to back they land in one server tick and the client only gets the unchanged final value
(Miscellania and the trough first showed nothing). A chore already done this period logs
nothing, so Herb Run was unticked first. This proves the wiring (the name resolves, the var
reaches the client, the rule fires), not what the var means. The user set this as the bar for
automatic. Which rules also had their meaning seen in play is below. A chore ticked by a check
stays done in the tracker until its reset: God Statues and Giant Oyster were picked and were
unticked by hand; the others, unpicked, stay marked (dailies and monthlies clear at 00:00 UTC
on 2026-11-01, the weekly ones on Wednesday 2026-11-04).

### Automatic: signal seen in the chore probe (2026-10-30), wiring checked

| Chore | Rule | Var set |
|---|---|---|
| Archaeology Research | `ARCH_RESEARCH_CONTRACT_1_STATE == 1` (only sending a team moves it into 1) | 0 -> 1 |
| Miscellania (daily, weekly) | `MISC_LAST_COLLECTION` rises | +1 |
| Bakriminel Bolts | any `SNIPER_BLOODTREE_<1..8> == 2` (felled), a rule per tree | tree 8, 1 -> 2 |
| Player-Owned Farm | any `POF_FEEDING_TROUGH_<1..6, BREEDING>_GENERAL_AMOUNT` rises (feeding). The collector farmhand (`POF_COLLECTOR_ANIMALS_STORED_SLOT_<n>` falling) isn't used: a plain `falls` needs a rule-language change | trough 1, 3 -> 4 |
| Herb Run | any `FARMING_SEEDS_PLANTED_HERB_PATCH_<n>` rises (planting): the first patch planted ticks the day. A per-patch count like the shop runs is the bigger option | patch 1, 1 -> 2 |

### Automatic: wiring checked, meaning from the var name and the wiki

The wiki facts are from runescape.wiki, read 2026-10-31; values read on the main account that
day in brackets.

| Chore | Rule | Doubt |
|---|---|---|
| God Statues | `GODSS_MONTHS_SINCE_USED` falls to 0 [3] | none big; never `GODSS_PLAYER` |
| Troll Invasion | `DNDTRACKER_TROLL_INVASION_LIMIT == 1` [0] | |
| Arc Contracts | `PGC_TALLY >= 3 + PGC_PER_DAY_INCREASE`, a rule per upgrade count [0, 4] | TALLY taken as the day's completions (wiki: 3 a day, +1 per Waiko upgrade, up to 7) |
| Menaphos Obelisk and Scarabs | `MENAPHOS_SCARABS_SQUISHED_TODAY >= 23` and `MENAPHOS_SOUL_OBELISK_DRAINED_AMOUNT > 0` [0, 0] | the obelisk's daily cap is 236 interactions, in units the 21-bit var doesn't show |
| Goebie Supply Run | `RAID1_GOEBIE_COURIER_LOOT_HANDED_IN_TODAY >= 10` [0] | |
| GWD2 Bounties | `GWD2_REP_TASK_LAST_DAY_GIVEN` rises (Feng gives a bounty) [233] | ticks on taking a bounty, not finishing one |
| Clan Citadel Cap | `CLAN_CLAIMED_XP_REWARD == 1` [0] | the boost, not the resource cap: the cap is on all resources together, and the rule language has no sum |
| Rush of Blood | `ELFCITY_SLAYER_WEEKLY_CHALLENGE_WAVES_COMPLETED` rises [0] | whether practice runs move it; `ELFCITY_SLAYER_WEEKLY_RESET`'s direction is unknown, so not used |
| Meg's Questions | `POP_MEG_ONMISSION > 0` [0, with her home] | ticks on her leaving; any non-zero away value works, and her return can't tick |
| Water Filtration | `DUEL_ARENA_REMOVAL_WATER_FILTRATION_LOOT_TIME` rises [0 in client and on the server] | whether it is the clean-out time; it is sent away from the oasis |
| Arc Supplies from Rosie | `ELR1_DAILY_SUPPLIES_TAKEN == 1` [0] | `ELR2_FREE_SUPPLIES` (4 bits) unused |
| Giant Oyster | `TUTISLAND_REWARD_OYSTER_FED_SEACUCMBER == 1` and `_SEAWEED == 1` [0, 0; `TUTISLAND_REWARD_STATE` 1] | ticks on feeding, the month's last step; looting last month's chest isn't seen |
| Penguin Hide and Seek | any `PENG_SPY_<0..11> == 1` or `PENG_SPY_BEAR_FOUND == 1` [all 0, none spotted this week]: the first spot ticks the week | the week's penguin count isn't in a known var, so "all found" isn't built; `PENG_SPY_POINTS` (35) and `_TOTAL_PENG` (311) look lifelong |
| Player-Owned Port | any `POP_VOYAGE_<1..4>_DONE` falls to 0 (sending a voyage) [all 1, voyages back]; or `POP_MARKET_QUANTITY` falls to 0 (buying the Black Marketeer's offer) [133] | the market rule is unproven: its `!setvar` came after the voyage had ticked the day |

### Automatic: seen ticking on the real activity (2026-10-31)

| Chore | Detector | What was seen |
|---|---|---|
| Invention Machines (daily, weekly) | any `INVENT_MACHINE_GUILD_<1..6>_OUTPUT` total falls (`core/detect.lua` `fell`): a collect. Filling isn't counted | the user collected from machine 3: `[CHORES] collected invention-machine from INVENT_MACHINE_GUILD_3_OUTPUT`, and the weekly one. After a client restart the outputs weren't held (`Inventory.Find` nil, even after `!inventmachinerun`) until the user reached the machines |
| Fort Forinthry Bonus XP | any `BONUSXP_<skill>` rises while the player is within 10 tiles of Aster (3302, 3571): a new `near` field in the rule language (`core/vars.lua`), the tile read only when such a rule's var changes. A lamp or star used beside Aster ticks it too | the user's claim raised `BONUSXP_AGILITY` 0 -> 1596975 beside Aster; then a `!setvar` of it there logged `seen fort-forinthry-bonus-xp done (BONUSXP_AGILITY)`. The Town Hall's own `PLAYER_FORT_GLE_TOTAL_XP_GAINED` never reaches the client |
| Bandit Duty Free | a shop row: Noterazzo's shop is the inventory `TAXFREE` (not `DT_BANDIT_SHOP`) | a purchase moved `TAXFREE`; after a reload a second purchase logged `purchase bandit-duty-free at Noterazzo, Bandit Duty Free`. The camp's bandits kill an unskulled player: get skulled by Mr Ex first (Edgeville, 3088, 3507).

### Confirmed manual (6)

| Chore | Why | What would move it |
|---|---|---|
| Nemi Forest | the map comes from outside the game; no var in the catalog | nothing in reach |
| Book of Char | its vars are `FMC_*` (the item is `FMC_FIREMAKERS_HANDBOOK`). Unleashing set `FMC_REWARD_BOOK_USE` to today's RuneDay (9012) on the server, but the client still read 0: it isn't sent. The client saw only the chat line "You unleash the power of the book of Char. You feel like you could burn any logs you touch!" (2026-10-31) | a chat detector (`chatAccess`) on that line |
| Rapid Growth | the cast moved only the patch's region-relative stage var (2026-10-30); `POF_RAPIDGROWTH_*` are the farm's patches | a chat line at the cap (`chatAccess`) |
| Big Top Bonanza | no var found (the `FMC_CIRCUS_*` vars are the quest's) | a change log during a show |
| Familiarisation | `DNDTRACKER_FAMILIARIZATION_*` is only the schedule | a chat line (`chatAccess`) |
| Skeletal Horror | only an NPC removal nearby shows the kill (NPC tracking is the extra-review tier); `CHEEVO_MINIGAME_CLUES_SKELETAL_HORROR` is a one-bit achievement | an `NPCEntityRemoved` detector near the boss: a new class |

## Evidence: the 2026-10-30 probe and earlier candidate notes

Kept for the evidence behind the rules above; where they differ, the audit above is current.

### Probed 2026-10-30: signals found, not built yet

The user did each chore on their main account (plugin dev server) while the dev bridge
forwarded every var change, inventory update, system chat line and menu pick (session
1b4060db2c; the cross-chore findings are in
[api-concepts.md](../api-concepts.md#vars) and, tagged "chore probe, 2026-10-30", under
[Inventories](../api-concepts.md#inventories)). Each signal
below was seen moving when the chore was done. "Rule" is the proposed detector; none is built.

| Chore | Signal seen | Rule | Build needs |
|---|---|---|---|
| Archaeology Research | `ARCH_RESEARCH_CONTRACT_1_STATE` (VarBit [0-1] of `_CONTRACT_1_1`): 0 idle, 1 team out, 2 back to claim. Send 0 -> 1; return 1 -> 2 (also chat "Your team has finished researching: <name>."); claim 2 -> 0. Only contract 1 exists | `done = { STATE == 1 }`: only a send moves it into 1 | a `data/vars.lua` row |
| Invention Machine (daily, weekly) | Per machine `config.Inv` `INVENT_MACHINE_GUILD_<1..6>_INPUT/_OUTPUT`. Collect: OUTPUT falls (7500 eternal planks -> empty; a disassembler's output is one `INVENT_MACHINE_DISASSEMBLER_DUMMY_OBJ`, its amounts in `INVENT_AUTO_DISS_HOTSPOT<n>_*` vars). Fill: INPUT rises. Kept current away from the guild. Charge: `INVENT_MACHINE_CHARGE_STORED` is one shared generator pool | tick on any machine OUTPUT falling (only a collect does that). Whether a fill is also needed is the user's call | an inventory-fall detector like the shop one (`shell/detect.lua`) |
| Miscellania (daily, weekly) | `MISC_LAST_COLLECTION` (6987) is the epoch minute of the last resource collect: 29806927 -> 29888984 on collecting. No chat line. The user: collecting is "the only thing that matters" | `rises = "MISC_LAST_COLLECTION"`; or "within this period", which also holds at login but needs a period-start operand in `core/vars.lua` | a `data/vars.lua` row |
| Bak Bolts | Eight Bloodwood trees: `SNIPER_BLOODTREE_<1..8>` (2 bits: 1 standing, 2 felled) and `_TIME_<n>` (minutes, 360 = the 6 h). Felling tree 8: 1 -> 2, time 357 -> 0. Single logs, shafts and tipping bolts move nothing; `CHEEVO_BAKRIMINEL_BOLTS` isn't a bolts counter | any `SNIPER_BLOODTREE_<n>` becomes 2 | a rule per tree, or a rule that takes a list of vars |
| Player Owned Farm | Collector farmhand: `POF_COLLECTOR_ANIMALS_STORED_SLOT_<1..3>` (stored, cap 10) and `_STORED_ANIMAL_ID_SLOT_<n>`; collecting took slot 1 10 -> 5. Troughs: `POF_FEEDING_TROUGH_<1..6, BREEDING>_GENERAL_AMOUNT` (of 1000) and `_CATEGORY` (food type); feeding 3 took trough 1 0 -> 3. Every main-farm trough read 0 before. Trough food wasn't seen falling in 45 min away | done: a collector slot falls, or a trough rises. Maybe a "needs feeding" state from an empty trough, right as of the last visit | a `falls` rule field (mirror of `rises`); a "due" state is a new chore class |
| Advance Time (already a rule, unproven) | A cast took `MAGIC_ADVANCE_TIME_CHARGES_REMAINING` 3 -> 2, chat "You have 2 casts of Advance Time remaining this week." | the existing `== 0` | two more casts to prove it |

What the farm doesn't give: per-animal health or produce. Animals are items in the
`POF_PADDOCK_*` inventories and a slot exposes only the item type and count, the game's pen
window can't be read, and the paddock inventories change once a minute on their own. The
paddock slot codes (`POF_ANIMAL_PADDOCK_<p>_SLOT_<s>`, 8 bits) look like a breed and stage code
(spirit yak 193, Fremennik yak 192; red sheep: newborn 86, ewes 90 and 94, ram 96), sent on
arriving at the farm. A stage table would take watching an animal grow. Beehives have
`POF_BEEHIVE_<n>_HONEYSTORED`, `_HEALTH`, `_HAPPINESS`; not probed. Produce gathered by hand
shows only as the chat line "You have gained N Farming XP and any harvested materials have been
added to your inventory."

Likely but not seen moving (read at login and on the day, no chore done):

| Chore | Likely vars (value read 2026-10-30) | Guess | Probe |
|---|---|---|---|
| Menaphos Obelisk/Scarabs | `MENAPHOS_SOUL_OBELISK_DRAINED_AMOUNT` (21 bits, 0), `MENAPHOS_SCARABS_SQUISHED_TODAY` (6 bits, 0), `MENAPHOS_TOTAL_REPUTATION` (3440319) | daily counters; done at a cap, else `rises` | drain until refused |
| Arc Contracts | `PGC_TALLY` (4 bits, 0), `PGC_PER_DAY_INCREASE` (3 bits, 4), `PGC_GIVER_ID`, `PGC_CONTACTS` (7 bits) | the Arc's contact contracts; TALLY counts done (to 7) or available (+4 a day) | hand in one contract |
| Herb Run | `FARMING_SEEDS_PLANTED_HERB_PATCH_<1..5, 9, DRUID, MYARM, WILDY, ECOSYSTEM_1/2>` (1/1/7/1/7/0/0/1/0/0/0): per patch, seeds in it; clear 7 -> 0, plant 0 -> 7. Not `FARMING_HERB_VARBIT_*`, which is region-relative | like a multi-shop run: the user picks patches, it ticks when each is replanted this period, "Herb Run (3/5)" | a harvest and replant; which number is which patch |
| Goebie Bands | `RAID1_GOEBIE_COURIER_LOOTED_TODAY`, `_LOOT_HANDED_IN_TODAY` (4 bits each), `_PARTICIPATED` (1 bit), all 0 | daily; done on PARTICIPATED -> 1 or hand-ins at the cap | one Supply Run |
| Rapid Growth | the cast moved only the patch's stage (`FARMING_HERB_VARBIT_3` 96 -> 97); `POF_RAPID_GROWTH*` are the farm's patches | no cast count seen; maybe a refusal line at the cap (chat) | casts 2 and 3 |
| Book of Char | no var found | activity only, unless using it moves a cooldown var | use it once |

### Var candidates: probe first, then the cheapest batch to build

| Chore | Period | Candidates | Probe must show |
|---|---|---|---|
| Capping Clan Citadel | weekly | `CLAN_CITADEL_PLAYER_RESOURCE_*` vs `CLAN_CITADEL_RESOURCE_CAP`; `CLAN_CLAIMED_XP_REWARD` | a resource reaching the cap, or a flag setting |
| Rush of Blood | weekly | `ELFCITY_SLAYER_WEEKLY_RESET`, `_WEEKLY_CHALLENGE_LEVEL`, `_WAVES_COMPLETED` | which marks the weekly run complete |
| Water Filtration | weekly | `DUEL_ARENA_REMOVAL_WATER_FILTRATION_LOOT_TIME`, `_PREVIOUS_LOOT_TIME` | LOOT_TIME after a clean-out, and its unit |
| Arc Supplies Crate | weekly | `ELR2_FREE_SUPPLIES`, `ELR1_DAILY_SUPPLIES_TAKEN` | which moves when Rosie's crate is claimed |
| GWD2 Bounties | weekly | `GWD2_REP_TASKS_AVAILABLE`, `_TASK_PROGRESS`, `_TASK_LAST_DAY_GIVEN` | AVAILABLE counting stored bounties; done = none left? |
| Giant Oyster | monthly | `TUTISLAND_REWARD_STATE`, `_HARVEST_COUNT_*`, `_OYSTER_FED_*` | which marks this month's chest claimed |
| Troll Invasion | monthly | `DNDTRACKER_TROLL_INVASION_LIMIT` (its base var is sent) | LIMIT -> 1 after all waves |
| God Statues | monthly | `GODSS_MONTHS_SINCE_USED`, `GODSS_LAST_RESET_MONTH`; **never `GODSS_PLAYER`** | MONTHS_SINCE_USED -> 0 after building |
| Player Owned Ports | daily | Black Marketeer `POP_MARKET_QUANTITY`; **never `POP_MARKET_RESOURCE_ROLLS`** | whether buying the offer zeroes QUANTITY. Borderline: ask the user before building. "Manage port" stays manual |

Read at login on 2026-10-30 (main account, away from each activity), so each is sent without
being there: `QUEST_EGW_FINALE_REWARD_STATION_XP_<skill>` 75000 for all six stations,
`GODSS_MONTHS_SINCE_USED` 3 (`_LAST_RESET_MONTH` 9, `_YEAR` 2026), `TUTISLAND_REWARD_STATE` 1,
`GWD2_REP_TASKS_AVAILABLE` 0 (`_TASK_LAST_DAY_GIVEN` 233), `ELFCITY_SLAYER_WEEKLY_RESET` 0,
`DNDTRACKER_TROLL_INVASION_LIMIT` 0, `POP_MARKET_QUANTITY` 133, `POP_MEG_CONFIDENCE` 22; every
`CLAN_CITADEL_*` and `DUEL_ARENA_REMOVAL_WATER_FILTRATION_*` var 0 (maybe unsent away from them).
Candidates the catalog adds: `ELFCITY_SLAYER_DUNGEON_REWARD_CHEST_OPENED` (Rush of Blood),
`DINO_TOTEM_RITUAL_COMPLETED`/`_PROGRESS` (totems), `FMC_CIRCUS_*` (Big Top Bonanza),
`CHEEVO_MINIGAME_CLUES_SKELETAL_HORROR` (Skeletal Horror).

### Game chat (needs the optional `chatAccess`)

| Chore | Period | Notes |
|---|---|---|
| Penguin Hide and Seek | weekly | chat is the route that avoids the penguin vars; the spotting lines are unrecorded |
| Meg | weekly | login line "You receive word that Meg has returned from her latest adventure." (wiki, not recorded) marks the reset, not the answers; `POP_MEG_CONFIDENCE` is a var candidate |
| Familiarisation | weekly | the `DNDTRACKER_FAMILIARIZATION_*` vars are only a schedule timer |

The 2026-10-30 probe recorded system lines for Archaeology Research, Advance Time and the
farm's produce (above), through the dev bridge's own `chatAccess`. None of this table's chores
has a recorded line yet.

### Activity signals

| Chore | Period | Signal |
|---|---|---|
| Skeletal Horror | weekly | `NPCEntityRemoved` of the boss nearby (NPC tracking is the extra-review tier); its clue alone has other sources |
| Big Top Bonanza | weekly | no var found; a change log plus chat during a show |

Inventory rewards (lamps, clues) have other sources, so an item alone gives false ticks: pair
it with location or a var. There is no interface-opened event.

### Unconfirmed shop

- **Bandit Duty Free** (weekly): candidate Inv `DT_BANDIT_SHOP`. Settled 2026-10-31: the shop
  is `TAXFREE`, now a proven row (see the audit above).

### Probably manual only

- **Nemi Forest**: the map comes from outside the game.
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

## Before submitting to Mod.io

- `plugin.json`'s `contactEmailAddress` is the placeholder `you@example.com`.
- Prove or drop the unproven rows: shop entries and var rules with `proven = false`.
- Ship without dev tooling: build the zip with `scripts/package-plugin.py chore-tracker`, which
  strips the `dev/` link, the `-- dev-only` marked Lua, `httpAccess` and `urls.rsdev`.
- Check the README's Mod.io sections against `docs/submission.md`.

## Known gaps

- The dev bridge's `MiniMenuEntrySelected` scrub (`plugins/dev-bridge/protocol.lua`,
  `entryView`) blanks names only on entries that target a player. A "Walk here" entry (action
  23) names a player standing on the tile, and that name went through to `dumps/rsdev/`.
- A dev-bridge eval's string value is cut to about 2 KB, ending `<+N bytes>`, though the bridge
  README lists only `Log` text, `Emit` tags and errors as cut. Return several values instead.
- No spec covers the VarTransmit domain filter: the harness would need a var with the same id in
  another domain.
- `docs/testing.md`'s replay "Not applied" bullet doesn't mention out-of-range ints (real values
  don't hit it).
- The dev recorder buffers silently until `httpAccess` is granted. A probe once sent nothing and
  nothing said why; always `ppr` then `ppe <plugin> httpAccess`.
- The chat sanitiser's `[0-9,]+` slots could pass an all-digit display name, if the game allows
  one. Allowlist review must use `[0-9,]` only where the game writes a number.
- `docs/vars/vars.csv` is regenerated from a dump; rerun `scripts/var-dump-analyze.py --catalog`
  after a game update (it lacked `HALLOWEEN26_PERM_1/2` on 2026-10-25).
