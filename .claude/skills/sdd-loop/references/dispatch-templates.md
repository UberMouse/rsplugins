# Subagent dispatch templates

Used by `sdd-loop` (§3 SDD loop, §5 branch-review fixes). Read this file before the first dispatch
of a run and again after any compaction or resume.

Give each subagent the **full task text inline**; never make it read a criteria file. Provide
scene-setting context (where the task fits, what earlier tasks already landed). Every dispatch
passes `model` explicitly. Never tell an agent it may skip `scripts/check-lua.sh` or work around a
failing check (a missing tool means the dev shell is not loaded: stop and report it).

## Slots

Every `<SLOT>` is filled by the conductor; the rest of the text is sent as written, except
`[CONDUCTOR …]` notes and sections marked "omit if".

| Slot | Fill with |
|---|---|
| `<TASK>` | the task title + what to do, verbatim |
| `<CRITERIA>` | the §0 acceptance criteria relevant to this task, verbatim |
| `<CONTEXT>` | the change, what prior tasks landed, the files involved, the plugin's local conventions (its `say()` tag, sliced-work pattern, constants block) |
| `<DOCS>` | the docs this task needs beyond `docs/README.md`, e.g. `docs/api-concepts.md` (events, UI, runtime limits), `docs/plugin-anatomy.md` (manifest, require, lifecycle, PersistentDB), `docs/guidelines.md` |
| `<COMMIT_MSG>` | an imperative subject in the repo's style (`git log --oneline`), e.g. `Add tile markers to walkable-flood`, plus a body saying why |
| `<TRAILERS>` | the commit attribution lines from the conductor's own instructions, verbatim (omit if none) |
| `<REQUESTED>` (spec reviewer) | the §0 acceptance criteria, verbatim |
| `<TASK_PARENT>` (reviewers) | the commit before this task's first commit |

## Fix modes — the Implementer template doubles as the fix agent

| Mode | Used by | `<FIX_FEEDBACK>` | Step 3 (commit) |
|---|---|---|---|
| **A. Per-task combined fix** | §3 step 3 | `This may combine findings from the parallel spec-compliance AND code-quality reviews in one pass — fix ALL of them together:` then the spec-review findings AND/OR code-review findings (both, when both flagged), inline | commits on top, as written |
| **C. Branch-review finding, stage-only** | §5 step 2 | the finding text + its resolution, inline, for one file group | **replace step 3** with: `STAGE only (git add <specific files>), do NOT commit — the conductor reviews the staged diff and commits.` |

## Implementer (also the fix agent)

```
Agent(implementer, model=implModel):
  description: "Implement <task-id>: <title>"
  prompt:
    You are implementing ONE task, working directly on main in the repo root (cwd). Earlier
    tasks (if any) are ALREADY COMMITTED — build on them. The beta client loads plugins/ from
    this checkout, so your edits are what the user will test. Never run `scripts/rsdev.py`
    (exec, events, shot): only the conductor drives the user's live client.

    ## Task
    <TASK>

    ## Acceptance criteria
    <CRITERIA>

    ## Context / where this fits
    <one paragraph: <CONTEXT>>

    ## Read first
    `docs/README.md`, then <DOCS>. Then the plugin's existing files, end to end.

    ## If this is a FIX dispatch, also:
    REVIEW FEEDBACK to address (do exactly this, nothing more).
    <FIX_FEEDBACK — see Fix modes>

    ## Before you begin
    If something is genuinely ambiguous and you CANNOT resolve it from the repo or the docs,
    STOP and return it as a question — do NOT guess. Otherwise proceed. If the task would build
    something `docs/guidelines.md` prohibits or puts under extra review, STOP and say which item.

    ## Your job
    1. Implement exactly what's specified, following the plugin's existing patterns. Every API
       call you write must match the reference: check each global, member, call form (`T:M`
       method vs `T.f` static), argument list, nil-able (`T?`) return and event payload field in
       the stubs in `docs/api/` (grep `docs/api/generated/`), confirming against
       https://developer.runescape.com/rs/ when a stub looks wrong or the detail matters (its
       search.json index has one entry per member: curl it to a temp file and query it with jq).
       Keep pure logic free of API calls (functional core /
       imperative shell). Work that scales with the world goes in bounded slices per `Logic` tick
       (the client kills any Lua call over 1000 ms). Debug logging goes through the plugin's
       tagged `say()`. Every function you add or change that returns a value gets a LuaLS
       `---@return <type>` line (`CLAUDE.md`); use `T?` where it can return nil.
    2. Format, then verify: `stylua <the .lua files you changed>`, then `scripts/check-lua.sh`
       must exit 0; it also runs the busted suite in `tests/`. Behaviour you add or change in a
       plugin gets specs in `tests/<plugin>/*_spec.lua` against the mock harness
       (`docs/testing.md`): scripted world-builder specs for scoped logic, recorded-timeline
       replay for integration paths. If the harness lacks an API the plugin needs, extend the mock
       (grounded in the stubs, with a fidelity-ledger row) rather than leaving the path untested.
       If your Bash tool lacks the dev shell, run tools through `direnv exec . <cmd>`. A missing
       tool even then means the dev shell is broken: STOP and report it.
    3. Commit your work (`git add <the paths you changed> && git commit` with message
       `<COMMIT_MSG>`, ending with `<TRAILERS>`). Never `git add -A` or `git add .`: the user may
       have unrelated uncommitted edits in the tree. Do NOT push.
       [CONDUCTOR, not sent: in fix mode C replace this step with the mode-C text from
        *Fix modes*; in every other dispatch delete this bracketed note.]
    4. Self-review with fresh eyes: completeness (all criteria met?), API grounding (every call
       checked in step 1? list any you could not confirm), runtime limits (any unbounded loop in
       one callback? per-frame work that could run once?), moderation (does the feature stay
       within `docs/guidelines.md`?), readability (could a Jagex moderator follow it in one
       reading?), discipline (no overbuild, followed the plugin's patterns?). **Verify every
       behavioural claim in a comment you added or edited** against the code and the docs; a
       claim you can't verify is deleted, not softened. Update the plugin's header comment and
       README if behaviour, keys or the log tag changed. Fix anything you find before reporting.
    5. Before your final message, stop every background shell or Monitor you started (commands
       over 120s are auto-backgrounded, so you may have some you didn't ask for).

    ## Report
    Lead with the commit SHA and the output of `git status --short`. Then, briefly: what you
    implemented, the `scripts/check-lua.sh` result, API uses you could not confirm, the
    in-client checks the user still has to run (`prl <plugin>`, what to do, what they should
    see, the log tag to grep), self-review findings, concerns — facts only, no restated diff or
    praise. State blocking questions in full.
```

## Spec-compliance reviewer

```
Agent(general-purpose, model=reviewModel):
  description: "Spec review <task-id>"
  prompt:
    Verify an implementation matches what was asked — built exactly that, no more, no less.

    ## What was requested
    <REQUESTED>

    ## What the implementer claims
    <implementer's report>

    ## Do NOT trust the report. Verify against the ACTUAL code.
    Read the committed diff (`git diff <TASK_PARENT>..HEAD`) and the touched files in full. Check:
    - Missing: anything requested but not implemented, or claimed-but-absent.
    - Extra: anything built that wasn't requested (over-engineering, unrequested features) —
      including anything the criteria explicitly put out of scope.
    - Misunderstood: right problem, wrong interpretation.
    - In-client checks: nobody can run the client from here. A criterion that names an in-client
      check is met when the implementer's report (and the README, where the criterion says so)
      gives the user exact steps and the expected result — never by a claim that it passed.
    - Moderation: a criterion that places the feature in a `docs/guidelines.md` tier is Missing
      if the code does something outside that tier.
    Cross-task coupling is REAL here (earlier tasks are committed) — don't flag a dependency
    that legitimately exists in the tree.

    ## Behaviour rows — check BOTH directions (omit-if: nothing requested is behavioural)
    If the request lists behaviour rows (a state × event matrix: "key pressed while a run is in
    progress", "permission revoked mid-upload", "plugin reloaded mid-job", or failure paths),
    check each one in the code:
    - Allowed: every `→ <effect>` row really happens on that path.
    - Disallowed: every `ignored` row is a deliberate early return or guard, not an accident of
      no handler existing; every `rejected` row tells the user (console line or UI) as stated.
    - Failure paths: each `IF <failure> THEN <response>` has a branch that leaves the stated
      state (not a `busy` flag stuck true, not an error that kills the callback mid-update).

    ## Verification scope — do NOT re-run the implementer's work
    Reading the diff is the job. The only commands you need are `git diff`/`git log`, reads,
    greps, and at most one `scripts/check-lua.sh`. Do NOT dispatch your own subagents.

    ## You never modify the tree
    Another reviewer is reading this same tree right now. Never edit a tracked file and never
    create a file under the repo — no temporary mutations, not even ones you would revert.
    Scratch goes in a `mktemp -d` directory only. If you want something proven to fail, name the
    exact mutation and the failure you expect in your report; the conductor has it run after
    both reviews return. Stop every background shell or Monitor you started before your final
    message.

    ## Report
    FIRST LINE, exactly: `SPEC: PASS` or `SPEC: FAIL`. Then the findings in this same final
    message (file:line, what's missing/extra/wrong) — a verdict whose findings live only in a
    tool call or a file is a verdict the conductor cannot act on. Then one line listing the
    touched files you read in full, and those you only grepped or skimmed.
    LAST LINE, exactly: `TREE: unchanged` (compare `git status --short` with what it showed
    when you started; if it differs, say `TREE: CHANGED — <what>`).
```

## Code-quality reviewer (runs in PARALLEL with the spec reviewer)

```
Agent(general-purpose, model=reviewModel|haiku):
  description: "Code review <task-id>"
  prompt:
    Code-review this task's committed change for QUALITY only. Do NOT re-check spec conformance —
    a separate spec-compliance reviewer runs in parallel on the same commit and owns that.
    Read the diff (`git diff <TASK_PARENT>..HEAD`) and the touched files in full. Report ONLY
    clear, high-impact issues; skip nitpicks and anything `scripts/check-lua.sh` rejects (syntax,
    manifest JSON, formatting, selene's unused / accidental globals, LuaLS's undefined names and
    type mismatches on typed values). LuaLS is blind through `any` (pcall results, untyped
    tables) and trusts the stubs, so API member names, call forms and nil flow there are YOURS.

    The criteria are the review lenses in `.claude/review-lenses/` — read
    `review-conventions.md` and the ones this task touches:
    - `review-correctness.md`: nil payload fields and `T?` returns indexed unchecked; `#` on
      non-sequences; `and/or` with false; integer vs float; pattern magic characters; multiple
      returns leaking; state across sliced ticks, entity removal and reloads.
    - `review-rs-api.md`: work that can exceed 1000 ms in one call; per-frame work in `Draw`;
      HTTP started from a completion callback; subscription-name collisions; lifecycle hooks
      declared `local`; `*Added` without a startup scan; UI components that never draw; manifest
      permissions and URLs; PersistentDB written every tick.
    - `review-api-grounding.md`: every API use checked against the stubs in `docs/api/` and, where
      it matters, https://developer.runescape.com/rs/ (curl its search.json index to a temp file
      and query it with jq) — a member that does not exist, `.` where the reference has `:`,
      wrong arguments.
    - `review-architecture.md`, `review-cleanup.md`, `review-comments.md`: functional core /
      imperative shell, a second way of doing what the plugin already does, stale header/README.
    - `review-moderation.md`: anything `docs/guidelines.md` prohibits or puts under extra review.

    ## Also check, for this task specifically
    <task-specific lens questions — the traps this change could plausibly hit, named by the
     conductor from the criteria and the touched files. Where possible, concrete probes to run
     in scratch: the input that should be refused, the pattern that would bypass a guard.
     Omit the section if there are none.>

    ## Verification scope — do NOT re-run the implementer's work
    Reading the diff is the job. If you genuinely need a build signal, run `scripts/check-lua.sh`
    once — nothing wider. Do NOT dispatch your own subagents.

    ## You never modify the tree
    A spec reviewer is reading this same tree right now. Never edit a tracked file and never
    create a file under the repo — no temporary mutations, not even ones you would revert.
    Scratch goes in a `mktemp -d` directory only. If you want something proven to fail, name the
    exact mutation and the failure you expect in your report; the conductor has it run after
    both reviews return. Stop every background shell or Monitor you started before your final
    message.

    ## Report
    FIRST LINE, exactly: `CODE: PASS` or `CODE: FAIL`. **Any Critical or Important issue means
    `CODE: FAIL`** — a PASS carrying Important findings is how fixes go un-re-reviewed.
    Then, in this same final message, issues only (Critical / Important / Minor, each with
    file:line + suggestion) — no Strengths or Assessment sections, and a PASS with no issues
    needs no further prose. Findings that exist only in a tool call or a file did not reach the
    conductor. Then one line listing the touched files you read in full, and those you only
    grepped or skimmed, and the scratch probes you ran.
    LAST LINE, exactly: `TREE: unchanged` (compare `git status --short` with what it showed
    when you started; if it differs, say `TREE: CHANGED — <what>`).
```

## Fix agent for §5 branch-review findings (fix mode C, one file group)

```
Agent(implementer, model=implModel):
  description: "Fix review findings in <file>"
  prompt:
    You are fixing specific, already-verified code-review findings in ONE file group, working
    directly on main in the repo root (cwd). Make ONLY the changes these findings call for — no
    drive-by refactors, no scope creep.

    ## Files
    <repo-relative paths>

    ## Findings to fix (each: id, what's wrong, the resolution to apply)
    <for each finding in the group, inline:>
    - [<id>] <file>:<line> — <summary>
      Problem: <description>
      Resolution: Fix per the suggestion: <suggestion>

    ## Context / where this fits
    <one paragraph: the plugin, what the change was for, its local conventions>

    ## Comments you write
    Read `.claude/review-lenses/review-comments.md` Part A first; every comment you add or edit
    must pass it. State the constraint the code satisfies now — never narrate the change, the old
    implementation, or this review (no "used to", "before this fix", finding ids, task labels,
    commit hashes), and never defend the change to a reviewer. Apply the halving test. A fix for
    a comment finding must leave the comment no longer than it was, unless the finding says a
    constraint is missing.

    ## If you genuinely cannot resolve a finding from the repo or the docs
    STOP and return it as a question — do NOT guess. Fix the others, report the blocker.

    ## Your job
    1. Read the files + the rest of the plugin first; follow its conventions. Apply each
       resolution exactly. Do NOT introduce a new bug while fixing: re-check nil and empty-table
       cases, any fallback you might defeat (`x or default` after a change that makes `x` false),
       and that any API call you add or change matches the reference (`docs/` or
       https://developer.runescape.com/rs/).
    2. `stylua <changed .lua files>`, then `scripts/check-lua.sh` must exit 0.
    3. STAGE the files you changed (`git add <the specific files>` — never `-A` or `.`). Do NOT
       commit and do NOT push — the conductor reviews the staged diff and commits.
    4. Self-review: did you address every listed finding, change nothing extra, keep the gate
       green?

    ## Report
    Per finding id: fixed / couldn't (why). Files staged, `scripts/check-lua.sh` result, any
    in-client check the fix changes, any blocker.
```
