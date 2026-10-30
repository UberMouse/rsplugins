# Review lens: moderation & guidelines

Every plugin meant for Mod.io is read line by line by a Jagex moderator and run in a closed
environment. This lens asks whether the change would get the plugin failed or sent back. The
criteria are `docs/guidelines.md` (read it in full first) and the live page it summarises,
https://developer.runescape.com/rs/submission/guidelines.html; `docs/submission.md` for the
listing and data-protection rules. `CLAUDE.md` adds: never build features that automate actions,
send inputs to the server, reveal hidden or future state, or export other players' info, and
**flag any borderline feature** rather than shipping it quietly.

Judge what the feature *does for the player*, not how the code is written. A harmless-looking
overlay that tells the player where to stand is prohibited; a scary-looking scan of vars that
only displays the player's own known progress is fine.

## Part A — prohibited (critical)

Walk `docs/guidelines.md` *Prohibited* item by item against the change. Each is a separate check:

- Automating gameplay, or sending inputs or actions to the game, **including new menu entries
  that send actions to the server**.
- Predicting future mechanics, attacks, safe spots, or NPC/player states beyond parity: next
  attack, mechanic start/end timers, countdowns or attack counters (except parity), projectile
  targets from hidden info.
- Prayer switching, ability recommendation or execution, indicating which prayer to use.
- **Automatically** showing where to stand or move (manually placed tile markers are fine).
- Revealing hidden information or game state; unhiding hidden interface components.
- Moving or resizing click zones (any 3D component; any part of action bars, inventory, worn
  equipment or familiar); modifying interfaces in ways that reduce difficulty.
- Showing which player an NPC is targeting.
- PvP advantages: scouting, targeting, opponent tracking, loot prediction.
- A detached camera giving an unfair advantage or unintended interaction.
- Changing the appearance of player-controlled models (hiding them entirely is allowed).
- **Exporting any information about other players**: over HTTP, into PersistentDB that is later
  sent, or into anything the plugin uploads. Reading `PlayerList` to *display* something is
  extra-review territory (Part B); sending it anywhere is prohibited.
- Deceptive or malicious behaviour; hidden functionality the description does not mention.

## Part B — subject to extra review (warning: flag it)

Not a rejection, but the change must surface it so a human decides: per `CLAUDE.md`, a borderline
feature is flagged, not silently built. Raise one finding per item the change newly triggers,
saying which item and why:

- Any permission requested (each needs a justification paragraph in the listing).
- Enemy timers, state tracking or combat info overlays; combat assistance from visible or
  deterministic information; combat-state features claimed as parity with existing content (name
  the content it is parity with, or say none was named).
- Navigation and guidance; non-combat timing, predictive or assistive tools.
- Input or menu customisation; detached camera features.
- Getting **any** information about other players, even for display.
- Shipping custom resources (images, sounds); depending on plugins that themselves need review.

Reviewers ask whether a feature automates decisions, reduces intended challenge, creates an
unfair advantage, or uses inaccessible or future-state information, and interpreted or
actionable recommendations get stricter review. A finding here says which of those questions a
moderator would ask of this change.

## Part C — data protection and the listing

- Data leaving the device (HTTP) needs a data-protection case (`docs/submission.md`): the endpoint,
  its country (the USA has no UK adequacy), a privacy notice. A change that starts sending data,
  or sends new categories of data, must be reflected in the plugin's description.
- What a plugin reads about the player must be what the description's data-protection section
  says it uses.
- The plugin's README / description must describe every feature a moderator will find in the
  code; an undocumented feature reads as hidden functionality.

## Part D — readability as a moderation requirement

Moderators fail code they cannot read ("major corrections"): obfuscated, minified, generated
without review, or too dense to follow. Flag a change whose logic a moderator could not follow in
one reading (deeply nested anonymous functions, single-letter names over long spans, clever
metatables or string-built code, `load`/`loadstring` of constructed source). The comments lens
owns comment quality; this Part is about whether the *code* can be moderated at all.

## Dev-only plugins

A plugin whose README and header say it is a dev tool "not for submission" (as `var-dump` does)
is never uploaded, so Part A/B findings on it are **info**, and Part C does
not apply, *unless* the change removes that marking, or builds a feature that would be prohibited
for any plugin and could be lifted into one. A dev tool that exports other players' info is still
a finding: `CLAUDE.md` forbids building it at all.
