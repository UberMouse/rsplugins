# Plugin guidelines (what moderation will accept)

Summarised from <https://developer.runescape.com/rs/submission/guidelines.html>. Jagex says the
list isn't exhaustive and will change, so check the live page before building anything
borderline, and ask on the Plugin Portal Discord when unsure.

## The principle

**May:** improve clarity, usability and accessibility. Organise and interpret information that is
visible, public, player-known or exposed by the API. Support planning, tracking and progression.
Send notifications and summaries based on known information.

**Must not:** act for the player. Substantially replace the player's decisions, skill, timing,
reactions or mechanical execution. Trivialise or fully solve content. Reveal hidden or future
information. Undermine competitive fairness. Mislead users, hide functionality, or behave
maliciously.

## Three tiers

### Generally allowed
- UI improvements and overlays that reorganise or clarify existing **non-combat** information
- Notifications for visible or already-known **non-combat** events
- Filtering, sorting, interface customisation
- XP calculators, planners, resource trackers using public or player-known data
- Logging and history (drops, kills, session stats)
- Manually placed markers and notes

### Subject to extra review (expect back-and-forth)
- **Any plugin that requests a permission**
- Enemy timers and state tracking; combat info overlays
- Combat assistance from visible or deterministic information that reveals no hidden or future
  state
- Combat-state features up to **parity** with existing combat design: recreating a visual
  helper the game already shows in some content (e.g. Sanctum-style enemy adrenaline bars,
  Elidinis-style fixed-area telegraphs, Vorago-clone-style markers) for other content
- Navigation and guidance systems
- Non-combat timing, predictive or assistive tools
- Input or menu customisation
- Detached camera features that allow world interaction or extended visibility
- Getting **any** information about other players
- Shipping custom resources (images, sounds)
- Depending on plugins that themselves need review

Reviewers ask whether the feature automates decisions, reduces intended challenge, creates an
unfair advantage, or uses inaccessible or future-state information. Interpreted or actionable
recommendations get stricter review.

### Prohibited
- Automating gameplay or sending inputs/actions to the game, **including new menu entries that
  send actions to the server**
- Predicting future mechanics, attacks, safe spots or NPC/player states (beyond parity): no next
  attack prediction, no mechanic start/end timers, no countdowns or attack counters (except
  parity), no projectile targets derived from hidden info
- Prayer switching or ability recommendation/execution, or indicating which prayer to use
- **Automatically** showing where to stand or move (manually marked tiles are fine)
- Revealing hidden info or game state, or unhiding hidden interface components
- Moving or resizing click zones: any 3D component, and any part of action bars, inventory, worn
  equipment or familiar. Modifying interfaces in ways that reduce difficulty
- Showing which player an NPC is targeting
- PvP advantages (scouting, targeting, opponent tracking, loot prediction)
- Detached camera giving unfair advantage or unintended interaction
- Changing the appearance of player-controlled models (hiding them entirely is OK)
- **Exporting any information about other players** (Jagex hopes to relax this later)
- Offensive, malicious or deceptive content. Lightly modified copies of someone else's plugin

## AI policy, and what it means for this repo

- Docs must be clear enough for a brand-new player. Code must be **clearly commented**, lean and
  human-readable. Obfuscated, transpiled, or *unvetted* AI-generated code gets rejected.
- AI tools (Claude Code explicitly named) are **allowed**, as long as the developer personally
  reviews and understands the code and the result is readable, documented and maintainable.
- Practical rule for this repo: every plugin gets a readable README/description and well-commented
  Lua. Review generated code before it ships.
