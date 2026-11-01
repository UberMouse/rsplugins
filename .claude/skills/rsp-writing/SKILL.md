---
name: rsp-writing
description: Write or edit prose a person reads in this repo, such as a plugin README, a mod.io listing (media/<plugin>/listing.md) or a docs/ page. Use when writing one, or when one reads verbose, padded or AI-written. Cuts detail the reader doesn't need, keeps the disclosures moderation needs, removes the tells Opus 5.5 still writes, and follows the repo's house style.
---

# Writing prose for this repo

Most bloat in this repo's docs is scope, not phrasing: a model describes everything it knows about
a feature, in the order it built it. Fix scope first (steps 1 and 2), then shape and sentences.
Sentence polish alone makes a verbose doc longer.

## 1. Name the reader and what they came for

| Document | Reader | What they came for |
|---|---|---|
| Plugin `README.md` (ships in the upload) | A player installing the plugin, and the Jagex moderator reviewing it | What it does, how to use it, what it does by itself, what it reads and stores, what it needs |
| `media/<plugin>/listing.md` | The same, on mod.io | As above, plus the required sections copied verbatim (`docs/submission.md`) |
| `docs/` pages | The next developer or agent | How the client, API or tooling behaves, and what to do about it |

Write only for that reader. A README keeps a short file map (moderators read the code) and the log
tag with its regex. Other developer material (naming conventions, a table of every log line, test
notes) goes in code comments or `docs/`.

## 2. List the facts, then cut by reader

Before rewriting, list every fact the text states. Keep a fact only if the reader can't learn it
by using the plugin and would act differently for knowing it.

Cut:

- **What use shows.** Cursor shapes, hover highlights, where a button or popup sits, popup wording
  and how long it lasts, that changes save at once, how wide something is, that a reset happens
  "even with the window open".
- **Mechanism.** How a queue dedupes, how a width is computed, how detection works inside. Keep
  one clause of mechanism only when it explains an outcome the reader would otherwise find
  surprising ("a purchase is an item's stock dropping while the shop is open" explains why a
  restock doesn't count). Cut the justification that follows a disclosure; keep the disclosure
  ("it takes no game input", not why it can't).
- **Edge cases of edge cases.** Name the rule, not every exception to it. A false positive or
  negative a reader could trigger by ordinary play is a caveat, not an edge case: keep it.
- **Repeats.** Say each thing once, in the section a reader would look in. The opening carries
  dependencies and permissions; the privacy statement goes in one place.

Keep, always:

- **Moderation disclosures**, in their exact words: anything that covers the screen or takes
  input, use of another plugin's private internals, permissions, what the plugin reads, what it
  stores, what leaves the device, and what it never shows (a var's value, hidden state). Words
  like "private", "invisible", "never" and "no game input" are the disclosure; shortening them
  away is a regression.
- **Every feature, named once.** A feature a moderator finds in the code but not in the README
  reads as hidden (`.claude/review-lenses/review-moderation.md`, Part C). A short description is
  enough; the behaviour doesn't need narrating.
- **What the reader can't discover:** what triggers an automatic action, defaults, reset times,
  status labels such as *unproven*, and caveats that change what to do ("a chore done while the
  plugin was off needs a hand tick").
- **Reference tables.** Keep them and make the cells terse: shorten the wording around the facts,
  keep names and numbers exact. Put a table under the bullet or heading it belongs to, and turn
  a sentence listing several defaults or values into a table.

When editing an existing doc, list every fact you dropped in your report so the user can veto it.
An edit pass on a doc that reads verbose should come out much shorter. If it got longer, you
polished sentences instead of cutting scope.

## 3. Shape

- Open with one or two plain sentences: what it is and what it needs (dependencies, permissions).
  No pitch.
- In reference lists, a bold label that leads each item is fine when it is what a reader scans
  for (an action, a setting). Don't turn a reference list into paragraphs.
- Put lookup data in tables (per-item rules, shops, files). Cells can be fragments: "claimed",
  "completed this week".
- Headings in sentence case that name what the section holds ("Resets", "Data"). No decoration.
- Write UI labels in the UI's own words, in bold: **How many to do**.
- If a code comment points at a README section (a plugin's `main.lua` header often does), keep
  the comment true: keep the heading, and if you cut what the comment says the section holds,
  update the comment.

## 4. Sentences

- **Active voice when the actor matters**, above all in privacy and behaviour claims: "The plugin
  never stores your position", not "Your position is never stored". Passive is fine when the
  actor is obvious or irrelevant.
- **Plain verbs:** is, has, uses. Not "serves as", "boasts", "leverage", "utilize".
- **Concrete over abstract.** Swap test: a sentence that could sit unchanged in another plugin's
  README says nothing about this one.
- **One point per sentence.** A parenthesis holds an aside, not a second clause.

Tells Opus 5.5 still writes (it rarely uses em dashes now; these persist). Each one used once
may be fine; a cluster means rewrite the paragraph around its point, not patch the phrase.

- Importance announced instead of shown: "This matters", "Why X matters", "importantly", "the
  key thing".
- Staged contrast: "not X but Y", "rather than simply", "is more than a X", "X, not Y" when no
  reader believed X.
- Evaluative filler: dependable, steady, thoughtful, meaningful, seamless, powerful, robust
  (figurative), "the most…", "one of the best".
- Closers that restate the paragraph, and send-offs: "Looking ahead", "what comes next".
- Run-ups: "Here's how it works", "Let's look at".
- -ing riders bolted onto a fact: "…, ensuring X", "…, making it easy to Y".
- Writing about the document: "the table below lists", "this section covers".
- Forced triads, and stacked hedges ("could potentially").
- Session leftovers: "the user wanted", "new", "now", "as before". Earlier versions belong in
  commit messages.

## 5. House style

- No serial comma: "daily, weekly and monthly".
- British spelling: behaviour, colour, licence (noun), centre.
- No em or en dashes in prose. Straight quotes.
- Wrap Markdown prose at 100 columns, like the rest of `docs/` and `plugins/`.
- When editing prose, leave code spans, paths, link targets, and the names and numbers in tables
  as they are.

## 6. Check before handing back

1. Read it as the reader. Could a player use the plugin from it alone? Could a moderator find
   every feature and every disclosure in it?
2. Compare the facts against step 2's list: each kept fact earns its place, each dropped one is in
   your report, nothing was added that the source didn't state.
3. Grep the draft for the tells:
   `grep -nE 'matters|not just|not only|rather than|more than a|—|–|ensuring|seamless|robust|powerful|dependable|thoughtful|meaningful|Here.s (how|what)|Let.s|Looking ahead|importantly|, and [a-z]+$' <file>`
   The last pattern catches some serial commas at line ends; check the rest by eye.
4. Report the word count before and after.

Adapted in part from blader/humanizer (MIT), joshuadavidthomas/agent-skills' writing skills
(Strunk and Orwell) and Wikipedia's "Signs of AI writing".
