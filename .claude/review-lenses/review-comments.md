# Review lens: comments

A comment here has two readers who have none of the author's context: the next person to change
the plugin, and the Jagex moderator who reads every line before approving it ("clearly commented,
lean and human-readable"; unreadable code fails moderation). Every comment in this change, whether
the change added it or merely modified the code around it, is judged against those readers.

Scope is **both** directions:

- comments the change **added** (`--` line comments and `--[[ ]]` blocks), and
- comments that **already existed** in code the change modified.

The second is where the expensive misses are: a diff that changes behaviour and leaves the comment
above it untouched actively misleads, and it is invisible unless you read the full file rather than
the diff hunk.

LuaLS annotations (`---@return`, `---@param`) are type declarations required by `CLAUDE.md`, not
comments: never flag one under Part A's WHY test. A stale one (the return shape changed under it)
is a Part B finding; a missing one is the architecture lens's.

## Part A — added comments

**Does it carry long-term explanatory value?** A comment earns its place by explaining the **WHY**:
the constraint, the trade-off, the client limit it works around (the 1000 ms cap, the HTTP
callback crash), the API quirk, where a constant's values come from in the docs. Flag trivial
comments that restate the WHAT the code already says (`-- loop over the locs`, `-- set shown to
true`, a comment that paraphrases the function name). Deleting a trivial comment loses nothing;
that is the test.

**Does it stand alone?** A comment must be complete for a reader who has only this plugin. Flag any
comment that only makes sense with context the reader does not have:

- References to the authoring session or conversation: "as discussed", "per the request above",
  "the user wanted", "see the plan", second-person address to a reviewer or requester.
- References to an unnamed prior state: "the new approach", "the old way", "this used to be X",
  "changed this to fix it", with no explanation a fresh reader can act on. Naming the historical
  alternative is fine when the comment says *why the alternative was wrong* (`plugins/var-dump`
  explains that an earlier coroutine version crashed the client: that is a constraint, not
  narration).
- Dangling pointers with no resolvable target: "see above/below" across a file, a "TODO" with no
  description, a reference to a branch, agent output, a session id or a scratch file.
- Labels from the plan or review that produced the change: `Task 2`, `T03`, `(phase 2)`, a review
  finding id (`W3`, `C1`), "from review", a commit hash. They name documents the reader will never
  see.

**Is it commentary on an intermediate state of the change?** Flag comments narrating the change
itself rather than the code: "temporarily disabled while we test", "first pass", "will clean
this up next", "adding this for now", a commented-out earlier implementation left beside the new
one. They are true only until the change lands, and noise forever after.

**Is it accurate?** Verify the comment against the code beneath it and against the API docs. A
comment that misstates what an API call returns or when an event fires is worse than none: the
moderator and the next author both trust it.

**Is it concise?** Explaining WHY earns a comment its place, not its length; length is earned line by
line. Apply the halving test: cut the comment in half, and if no constraint, trade-off or reason a
future reader can act on went with the half you removed, it was twice as long as it needed to be.
Flag it with the shortened text as the suggestion; "too verbose" with no replacement is not a
reviewable finding.

Lines that routinely fail this test while still being genuine WHY:

- **The derivation behind a conclusion the comment already states.** The reader needs the
  constraint the value satisfies, not the tour of values that did not satisfy it.
- **The same reason restated in a second register**: the "in other words", the closing sentence
  that recaps the opening one.
- **The change defending itself to a reviewer**: "this is NOT just X", "nothing yet forces this
  to live here". It argues with a reader who is not there.

A plugin's header comment (what it does, its keys, whether it is for submission) and a comment on
a subtle invariant can rightly run several lines. Ten lines on a colour constant cannot.

## Part B — existing comments in modified code

For every file the change modifies, read the surrounding comments in **full file** context, not
the diff hunk, and check each against the code as it now stands:

- **Stale**: the comment describes behaviour the change replaced. A contradiction between a
  comment and its code is a **warning**: the next reader will trust the wrong one. If following
  the stale comment would cause a freeze, a crash or lost data, it is **critical**.
- **Orphaned**: the comment explains a branch, constant, field, key binding or guard the change
  removed or renamed.
- **Narrowed or widened**: still reads as true but no longer states the whole constraint (a case
  the change added, a guarantee it dropped).
- **The plugin header and README.** The header comment at the top of `main.lua` and the plugin's
  `README.md` describe its behaviour, keys and log tag. A change to any of those that leaves the
  header or README describing the old behaviour is a Part B finding.
- **Comments that justify a suppression**: the reason beside a `-- selene: allow(...)` or
  `-- stylua: ignore` must still hold after the change.

Do **not** flag a pre-existing comment the change did not touch and did not invalidate.

## Part C — missing comments

Moderation asks for clearly commented code, so the bar for "missing" is lower than in most repos,
but it is still *genuinely non-obvious* code: a workaround for a client limit or crash, a constant
whose value comes from the docs or from measurement (cite where), a deliberate ordering or tick
dependency, a packed key or bit layout, a guard whose reason is invisible from the code, an API
behaviour the code relies on that the docs do not state. Flag these as **info** with the concrete
WHY that should be recorded. A new plugin without a header comment saying what it does is a
**warning**.

Never ask for a comment on self-evident code. Adding a redundant one is itself a Part A finding.
