# Chore Tracker

A checklist for RuneScape's repeatable chores, the daily, weekly and monthly tasks such as the
Daily Challenge, Soul Reaper or the Giant Oyster. Pick the ones you do, tick them off as you go,
and they clear themselves when the game's reset comes round. It is a planner you tick by hand:
it never reads what you did in game, does nothing for you, and sends nothing anywhere.

## Using it

- **Opening it.** Enable the plugin and a window titled **Chores** opens. On the first run it
  says no chores are picked yet.
- **Picking chores.** Click the settings button at the top left of the window. Every chore is
  listed under Daily, Weekly and Monthly; ones that are bought from a shop end in "(shop)".
  Tick the ones you want to track: changes save straight away. Click the back button to return
  to your list.
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
- **No permissions.** The plugin reads the game clock and your own character's display name,
  both of which plugins can read without one.

## Credits

The chore list (names, descriptions, wiki links and reset periods) comes from
[dailyscape](https://github.com/dailyscape/dailyscape.github.io), used under its MIT licence.
`data/chores.lua` holds the copy, the licence text, and how to regenerate it.

## Console lines

Everything the plugin logs carries the tag `[CHORES]`: loading, collapsing and expanding,
character changes and waiting for the clock. It never logs your display name. Grep regex:
`\[CHORES\]`.

## Files

| File | What |
|---|---|
| `main.lua` | The window, its collapsed button, the two views, and following the login and clock |
| `shell/store.lua` | Saving and loading in PersistentDB |
| `core/period.lua` | When each reset period began (pure arithmetic on epoch minutes) |
| `core/state.lua` | Picks and ticks, and whether a chore is done now |
| `core/view.lua` | What the list shows, as plain data |
| `core/layout.lua` | The saved window layout, read back and kept on screen |
| `data/chores.lua` | The dailyscape chore list (generated) |

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
This plugin uses the following information: the game clock, your own character's display name, and the chores you pick and tick.
This information is not transmitted outside of the plugin under any circumstances.
Your picked and ticked chores are stored on this device in the plugin's PersistentDB, under your character's display name, with the window's position, size and collapsed state.
```
