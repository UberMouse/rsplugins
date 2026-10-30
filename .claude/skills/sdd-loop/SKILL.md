---
name: sdd-loop
disable-model-invocation: true
description: Run a small, already-understood plugin change through the subagent-driven-development review loop end to end, with no artifact-review gates. You ASK whatever you need to pin the ask down, restate it as acceptance criteria, implement it (usually as ONE task) via a fresh subagent, review each task with a spec-compliance and a code-quality reviewer IN PARALLEL, fix-forward until both are clean, then run the autonomous code review workflow over the run's commits, auto-fix its primary findings, and hand back reviewed commits on main plus the in-client checks for the user to run. Use when the work is too small to plan but should still be reviewed.
---

# SDD Loop (lightweight, ungated)

Subagent-driven development without a planning pipeline: no approach gate, no plan gate, no
review gate. You take the ask, pin it down, implement it under subagent-driven development, let
the autonomous reviewers converge, and hand back reviewed commits on `main`.

> **Ungated does not mean silent.** What's removed is *artifact* review: you never hand the user
> a plan, a spec, or a report and wait for approval. **Asking questions is not a gate; ask
> freely**, especially at intake (§0), where you derive the criteria the whole loop is judged
> against. Get the ask wrong there and every downstream reviewer faithfully validates the wrong
> thing. A question costs one round-trip; a wrong spec costs the whole run.

**Core principle:** a change is done not when it works, but when a reviewer that did not write
it, reading the real committed tree, cannot find anything wrong with it. Here that bar has a hole
no reviewer can fill: no subagent can touch the client. The conductor can, through the dev bridge
(*Prerequisites*), but only the user can play it. So the loop ends with in-client checks: the
conductor runs the console half and reports what it saw, the user does the rest. It never claims
the change works in game on the strength of the tests.

**Announce at start:** "Using the sdd-loop skill — implementing this under subagent-driven
development with autonomous review. I'll ask up front if anything's ambiguous, then run without
planning gates."

```
  0. Intake        ASK what you need ─► restate as ACCEPTANCE CRITERIA (the spec surrogate)
  1. Setup         preflight (dev shell, gate green, touched paths clean); record BASE; state.json
  2. Split         DEFAULT: one task. Split only if genuinely separable (2-4, primitives-first)
  3. SDD loop      per task, sequentially:
                     implement ─► ⟨spec-review ∥ quality-review⟩ ─► one combined fix
                       ─►(re-review what the fix addressed)*─► task done, committed
  4. Verify        scripts/check.sh exits 0 (it also runs the JS tests and hook selftests)
  5. Code review   Workflow(branch-code-review.js, base: BASE) ─► auto-fix every PRIMARY finding
                     ─► conductor adjudicates each appendix finding (fix / reject / defer) ─► re-verify
  6. Hand back     reviewed commits on main + the in-client checks for the user; phase done
```

## When to use

- A bug fix, small feature, or refactor to a plugin (or the repo's scripts and tooling) that you
  already understand and don't want to plan.
- You want independent spec + quality review and fix-forward without sitting through gates.
- Long unattended runs: the questions are front-loaded at §0, so once answered the loop runs to
  the hand-back without stopping again.

## When NOT to use

| Situation | Do instead |
|---|---|
| A new plugin, competing designs, a feature whose guideline tier is unclear | Plan it with the user first (plan mode, or talk it through); this loop has no approach gate |
| Code is already written; you just want it reviewed | Run `Workflow({ scriptPath: ".claude/workflows/branch-code-review.js", args: { base: "<sha>" } })` standalone |
| A typo, a comment, a version bump | Just edit it. Three subagents to fix a typo is theatre. |

If mid-loop the work turns out to need genuine design work, do **not** silently keep going; see
*Escape hatch*.

## Prerequisites

- **Work on `main`, in this checkout.** No branch, no worktree (`CLAUDE.md`): the beta client's
  `dev_plugins` symlink points at this checkout's `plugins/`, so a worktree's changes would be
  invisible to the user's in-client testing. Every task commits to `main`.
- **The dev shell** (direnv or `nix develop`): `scripts/check.sh` needs `luac`, `selene`,
  `stylua`, `lua-language-server`, `python3`, `busted`, `node`, `jq` and the `docs/api/` stubs
  symlink the shell makes. Claude Code's direnv hooks load the shell into every Bash
  tool, subagents' included (`README.md`), so run tools directly. `lua: command not found` means
  the hook failed (e.g. `.envrc` not allowed): stop and say so.
- **Stop a background process by its task id or PID, never `pkill -f <pattern>`**: the shell
  running that command has the pattern in its own command line, so it kills itself (exit 144).
- Human input comes only through `AskUserQuestion`, so this loop works in a background job.
- **The live client, through the dev bridge: conductor only.** When the user has the client open,
  `scripts/rsdev.py status` says whether the `dev-bridge` plugin is connected
  ([docs/dev-environment.md](../../../docs/dev-environment.md#dev-bridge)). If the daemon is
  down, the conductor starts it (`scripts/rsdev.py start`). If the bridge is connected, the
  conductor runs console commands (`exec "prl <plugin>"`), reads forwarded events (`events`) and
  captures the window (`shot`, then Read the printed path). Implementers, fix agents and
  reviewers never run `rsdev.py` (the templates say so). Two agents must not send console
  commands to the user's client at once, and every action should show in the conversation the
  user is watching.

## State you carry

| Field | Meaning |
|---|---|
| `criteria` | the acceptance-criteria list from §0 — the spec every spec-review checks against |
| `tasks` | usually one; each with title, criteria slice, files, the docs it needs |
| `BASE` | the commit the run starts from; §5 reviews `BASE..HEAD` |
| `implModel` | `sonnet` default; `opus` for a genuinely hard change |
| `reviewModel` | `sonnet` default; `haiku` for a trivial task |

**Persist it** as durable state in `.durable-state/state.json` (gitignored). **Read
`.claude/skills/durable-state/SKILL.md` before the first write**: it owns the generic contract
(write discipline, `inFlight`, `standingInstructions`, `phase: "done"`, the resume hook,
handoff). What sdd-loop adds:

- **`skill`**: `"sdd-loop"`. **`phase`**: `implement` (§1–§5) → `done` (after §6's report).
- **Owner fields**: `base` (set-once, §1), `branch` (`main`), `implModel`, `reviewModel`.
- **`tasks[]`** entries add `commit`, `spec`/`code` verdicts, `fixRounds` and `agentInFlight`.
- **`invariants`**: the three under §Resuming step 3, one line each.
- **`notes`**: unrelated uncommitted files found at §1 (never to be staged), and anything you
  noticed but kept out of scope.
- Write `.durable-state/tasks.json` once after §2: each task with its §0 criteria slice verbatim
  as `acceptanceCriteria`, so the criteria survive compaction too. It is the conductor's copy;
  agents still get the criteria inline, never as a file.
- Rewrite `state.json` on every task transition (dispatched, reviewed, fixed, done), keeping
  `tasks[]` verdicts, `fixRounds`, `agentInFlight` and `inFlight` accurate.

## Resuming — after compaction, a resume, or a handoff

After compaction the harness may re-attach this skill truncated, or not at all. Whatever you
remember about the loop, re-read it:

1. `Read` this file's §3 (the loop) and `references/dispatch-templates.md`, then follow
   `.claude/skills/durable-state/SKILL.md` §Resuming (Read `.durable-state/state.json` and
   `tasks.json`; check `inFlight`). Its `standingInstructions` are the user's words and still
   bind.
2. Run the §1 **preflight** (it runs on every resume), then continue from the first task that is
   not `done`. A task whose `agentInFlight` died on an API error: see §3 step 1. If every task is
   already `done`, `Read` §4–§6 too, and find where the tail stopped from the tree:
   - A staged but uncommitted diff → a §5 fix group stopped mid-review; do §5 step 3 on it first.
   - Otherwise re-run §4, then §5 from the start. Both are safe to repeat: review-fix commits
     already on `main` are earlier groups that landed, and the fresh review sees them.
3. Invariants that drift after compactions:
   - **The conductor never edits the task's files for a task or a finding.** Implementers and
     fix agents do; a hand-implemented task skips both reviews.
   - **Every Agent call passes `model` explicitly** (`implModel` / `reviewModel`). An omitted
     `model` inherits the conductor's model.
   - Every dispatch uses the templates (FIRST LINE verdicts; implementers commit their own work
     with explicit `git add <paths>`).

**Handoff**: per `durable-state` (rewrite `state.json` now; give its absolute path and this
skill's path).

---

## 0. Intake — ask, then write the acceptance criteria

There is no plan document and no spec document. **This list is the spec.** Without it the
spec-compliance reviewer has nothing to check against and degenerates into a second code review.

That makes this the **highest-leverage step in the loop**, and the only one where a human is
cheap to consult. Everything downstream faithfully executes whatever you write here.

### 0a. Read the code and the docs first

Read the plugin the ask touches, end to end, and `docs/README.md` plus the docs it points at for
the API areas involved, **before** asking anything. Look up any var the ask mentions in
`docs/vars/vars.csv`. Most apparent ambiguities dissolve on contact with the code: the plugin's
existing key handling, its sliced-work pattern, a neighbouring function that already answers it.
Questions you could have answered by reading are noise, and they train the user to stop reading
your questions.

### 0b. Ask what's actually load-bearing

Then **use `AskUserQuestion` for whatever survives.** You are pinning down the ask, not asking
permission. Batch it into one call (up to 4 questions, options with real trade-offs in the
descriptions) so it's a single interruption.

**Ask when** two readings of the ask would produce **materially different code**:

- Scope boundaries: this plugin only, or a shared module two plugins would use?
- Behaviour at edges the ask didn't mention: logged out or loading, an instance, nothing nearby,
  a busy area, the plugin reloaded mid-job, a permission not granted or revoked.
- **Moderation tier.** Anything that touches combat, other players, navigation, timing, input,
  menus, permissions or shipped resources: where it sits in `docs/guidelines.md`, and whether the
  plugin is for submission or a dev tool. A borderline feature is the user's call, never yours
  (`CLAUDE.md`).
- What persists: which settings survive a reload or a client restart (PersistentDB), and whether
  per character.
- An intentional-looking oddity in the code you'd otherwise "fix"; it may be working around a
  client limit (`docs/api-concepts.md`, *Runtime limits we've hit*).

**Don't ask; decide and note it** when the answer is conventional, cheap to change, or the repo
already votes: naming, file placement, whether to extract a helper, the log tag (the plugin's
existing one), anything a neighbouring plugin already demonstrates.

For these, pick the repo-conventional option and write it into the criteria as an explicit
`**Assumption:**` line. The user sees it in the criteria echo and the final report; if it's
wrong they say so, at the cost of one line instead of a round-trip.

**If the ask is a one-liner with no real ambiguity, ask nothing.** The test: would a wrong guess
cost more than the interruption?

### 0c. Write the criteria

Restate the ask as a short, checkable list of what must be true when this is done:

```
## Acceptance criteria
- [ ] `<function>` in `plugins/<name>/main.lua` <does X> instead of <Y>
- [ ] <edge case> is handled: <expected behaviour>
- [ ] Moderation: <the docs/guidelines.md tier this sits in, and why> — or: dev tool, not for submission
- [ ] README and header comment describe <the new behaviour / keys>
- [ ] In-client check (for the user): `prl <name>`, then <action> → <expected overlay / console line tagged [TAG]>
- [ ] No change to <thing explicitly out of scope>
```

Rules:

- **Keep it to what the user asked for.** Improvements you noticed go in `notes` and the final
  report, not criteria.
- **Include an explicit out-of-scope line** when the ask has an obvious adjacent temptation, so
  the spec reviewer can flag over-building as a defect rather than a bonus.
- **Always include the moderation line and at least one in-client check.** The moderation line
  is what lets the spec reviewer reject a feature that drifted into a prohibited tier. The
  in-client check is the only behavioural test this repo has: write it as steps the user can
  follow and the result they should see.
- **Fold the answers in.** Every §0b answer and every `**Assumption:**` belongs in this list;
  that is what makes it enforceable. An answer you merely remember is one no reviewer can check.
- **Stateful change? Write criteria for the states it doesn't mention too.** When the change adds
  or alters a key binding, an event handler or a sliced job, list each state the input can
  arrive in, not just the one the ask is about. Mark each handled, ignored on purpose, or
  rejected with what the user sees. Also give the failure path
  (`IF <failure> THEN <state + message>`). The spec reviewer checks both directions, but only for
  what you list here:
  ```
  - [ ] Recompute key while a run is mid-slice: restarts from scratch (old job dropped, not merged)
  - [ ] Toggle key before the first run: ignored; no error
  - [ ] IF the player entity is nil (loading) THEN skip this run and log "[TAG] not logged in"
  ```

**Echo the criteria to the user as narration, then keep going; do not wait for approval.** You
asked your questions in §0b; now you report what you concluded, without requesting sign-off. If
they disagree they'll say so; the loop doesn't stop to find out.

The criteria live in your context and are passed **verbatim inline** to every subagent. Never
write them to a file for an agent to read (`tasks.json` is the conductor's copy).

## 1. Setup

**Preflight — here AND on every resume.**

```bash
git rev-parse --abbrev-ref HEAD      # must be main
git status --short                   # see below
scripts/check.sh                     # must exit 0 before any task is dispatched
S=.durable-state/state.json
mkdir -p .durable-state
[ -f "$S" ] || jq -n --arg sid "$CLAUDE_CODE_SESSION_ID" '{skill: "sdd-loop", sessionId: $sid}' > "$S"
# BASE is set ONCE, on the first run; a resume reads it back. Re-taking HEAD after a task has
# committed would drop that task from the §5 review's range.
BASE=$(jq -r '.base // empty' "$S")
if [ -z "$BASE" ]; then
  BASE=$(git rev-parse HEAD)
  jq --arg base "$BASE" '.base = $base | .branch = "main"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
fi
```

- **`git status`**: a file this run will touch must be clean; if one is dirty, stop and
  reconcile with the user, because building on an unknown state makes every review diff
  meaningless. Other uncommitted files (the user's own edits) are left alone: record them in
  `notes` so no agent stages them (every template uses explicit `git add <paths>`).
- **`scripts/check.sh` red at start**: stop and report it. Do not let a task inherit a red
  gate; its reviewers would spend their pass on someone else's failure.
- A missing tool means the dev shell is not loaded: stop and say so.

Write state.json (`phase: "implement"`, `base`, `branch`, model tiers, `invariants`, `notes`).

## 2. Split only if you must

**The default is ONE task.** A small change reviewed as one commit gives the reviewers a diff
they can hold in their heads; that is the whole advantage of the lightweight loop.

Split into 2-4 tasks only for genuinely separable units, e.g. a pure module that later work
requires, or two independent plugins with no interaction. Order **primitives-first**: whatever
creates a shared module or function lands before its consumers.

No task document, no planner, no gate. Wanting five or more tasks is the signal you need a plan
(see *Escape hatch*).

## 3. The SDD loop

Run tasks **strictly sequentially**. Each task edits the real tree and commits; git on disk is
the durable state.

1. **Dispatch the implementer** (`Agent`, `implementer`, `model: implModel` — explicitly) with
   the *Implementer* template from `references/dispatch-templates.md` (Read it before the first
   dispatch). It implements the task, runs `scripts/check.sh`, **commits**, and self-reviews.
   Record it in state.json (`in-progress`, `agentInFlight`, `inFlight`).
   - If it returns a **blocking question**, route it through `AskUserQuestion` and re-dispatch
     with the answer. Do not answer on the user's behalf when the answer is a real decision
     (anything in the moderation tiers always is); equally, don't escalate a choice the repo
     already answers.
   - **An agent that died on an API error** (529/500): check `git status --short` and
     `git log -1`. It left edits ⇒ resume that same agent with `SendMessage`; it left none ⇒
     re-dispatch from the template.
2. **Review in PARALLEL.** Dispatch BOTH reviewers **in a single message** against the SAME
   commit, each with `model` passed explicitly. Add both to `inFlight`; remove each when its
   notification arrives. Neither modifies the tree, so they cannot conflict and there is no
   spec-before-quality ordering:
   - **Spec-compliance reviewer** (`reviewModel`): checks the committed code against the §0
     criteria: missing, extra, or misunderstood.
   - **Code-quality reviewer** (`reviewModel`, `haiku` for a trivial task): quality only, against
     the lenses in `.claude/review-lenses/`. Fill its *Also check* section with the traps this
     change can plausibly hit (an unbounded loop in a callback, a new API call to ground, a
     teardown path). Where you can, name **concrete adversarial probes** for it to run in
     scratch (the input that should be refused, the pattern that would bypass a guard, the
     payload field that can be nil), not only areas to look at: a reviewer reliably finds
     the holes it is pointed at, and rarely the ones it isn't.
   - **Falsification.** A reviewer that wants something proven to fail names the exact mutation
     and the expected failure; it never applies it. Have it run only after BOTH reviewers have
     returned, by the next fix agent. Never ask a reviewer running in parallel to mutate code.
3. **Converge.** A dimension is **flagged** if it returned FAIL, or PASS with any finding you send
   to a fix agent. If either flagged, dispatch **ONE combined fix agent** (Implementer template,
   fix mode A, `model: implModel`) carrying *both* finding sets, so a single pass closes spec and
   quality gaps together. Add it to `inFlight`; remove it when its notification arrives. It
   commits on top. Then **re-run each review the fix addressed**: every fix commit is re-reviewed
   by every dimension whose findings it touched; a dimension that came back clean and wasn't
   touched drops out. Repeat until every review that ran most recently is clean. **You never
   apply an in-loop fix yourself**: a conductor edit counts as a fix round and still gets
   re-reviewed.
4. **Close the task and start the next one in the same turn.**
   - Record the task in state.json: `done`, commit, `spec`/`code` verdicts, `fixRounds`,
     `agentInFlight` cleared. A task not implemented and reviewed through this loop is
     **UNREVIEWED**: run its reviews before moving on, or tell the user. §6's report is written
     from these records, so they must be true.
   - **A guard that protects privacy, moderation or data** (a sanitiser, an allowlist, a
     permission check, a fail-closed path): before closing the task, probe it yourself. Write
     inputs that try to get past it and run them against the committed code from a scratch
     dir (read-only on the tree). The implementer, the fix agent and the reviewer each test
     the cases they thought of; a hole none of them imagined is found only by someone trying
     to break it. A hole you find goes to a fix agent like any finding.
   - Run `ListAgents` and `TaskStop` any completed agent still listed.
   - **Dispatch the NEXT task's implementer in the SAME turn as any progress note**, and add it to
     `inFlight`. A turn that ends with tasks left and no Agent or Workflow in flight is a
     **stall**.

**Rules — do not break these:**

- **Only ONE agent edits the tree at a time**: never two implementers, never two fix agents. The
  two *reviewers* run concurrently only because they never modify it.
- **The conductor never edits the task's files for a task or a finding**, and **every Agent call
  passes `model` explicitly**.
- **Never skip a review, never proceed with open findings.** The task is done when both
  dimensions are clean, not when the gate is green.
- **Re-review is targeted, not blanket**: a clean dimension the fix didn't touch is trusted to
  stay clean. §5 is the backstop that sees the whole change.
- **Fix-forward only.** Fix agents commit on top; never rewind, amend or rebase a prior task's
  commit.
- **Git-on-disk is the state.** Commit every task. A dirty or inconsistent tree at task start
  (beyond the `notes`-listed unrelated files) ⇒ stop and reconcile.
- **Scope discipline.** Tech debt found along the way goes in `notes` and the final report, not
  extra commits.

## 4. Verify

The conductor runs these itself (they are read-only checks):

```bash
scripts/check.sh                                       # always; must exit 0 (its header lists the steps)
git diff --name-only "$BASE" HEAD                      # what the run touched, to pick the rest:
python3 -m py_compile scripts/<changed>.py             # if a Python script changed
```

Do not proceed to §5 with a red check; the reviewers would waste their pass reporting symptoms
of a broken tree. A red check here is a fix round: dispatch a fix agent (Implementer template,
fix mode A, the failure output as `<FIX_FEEDBACK>`), never a conductor edit.

## 5. Autonomous code review — auto-fix the primaries

The per-task reviews saw one task each. This is the only pass that sees the change **as a
whole**, which is where cross-task coupling bugs live, and the only one that grounds every API
call against the reference and walks the moderation guidelines item by item. It is not optional,
even for a one-task run.

```
Workflow({ scriptPath: ".claude/workflows/branch-code-review.js",
           args: { effort: "medium", base: "<BASE>" } })
```

It returns `{ reportPath, reportWritten, findingsList, incomplete, coverage, primary, appendix, critical, warning, info, … }`,
each finding tagged `tier: "primary" | "appendix"` with a stable id (C1, W3, I2…).

**Reading the result.** The completion notification truncates a large return value, so parse the
task's output file rather than the notification text. That file is a JSON envelope (`summary`,
`logs`, `result`, …), and the return value is under `result`, sometimes as a JSON string:

```bash
jq '.result | if type == "string" then fromjson else . end
    | {primary, appendix, incomplete, reportWritten, reportPath, n: (.findingsList | length)}' <output-file>
```

`reportWritten: false` means the report file is missing (the review itself is complete): work
from `findingsList`. Each finding's `bands` is one letter per verifier vote (A–D, or `refuted`);
a finding is primary when at least half its non-refuting votes are at or above the effort's band.

- **`skipped: true`**: no changes in `BASE..HEAD`, or the base did not resolve. Something is wrong
  upstream; stop and say so.
- **`incomplete: true`**: a lens died or left comment-checklist items unresolved
  (`coverage.failed`, `coverage.checklistMissing`), so part of the change was not reviewed. Do
  **not** treat the findings as the verdict or skip to §6. RESUME the same runId once the cause
  clears (only the failed lenses re-run). If it stays incomplete, stop and report which lenses
  and items are missing as a blocker; never finish the loop on a partial review.
- **Zero findings**: go to §6.
- Otherwise **fix every `primary` finding.**
- **Adjudicate every `appendix` (low-confidence) finding yourself; do not hand them to the
  user.** The user asked for this. For each one, read the cited code and decide:
  - **Fix**: the problem is real and in scope. It joins the fix groups below, exactly like a
    primary finding.
  - **Reject**: the finding is wrong, or the change isn't worth making. Give a one-line reason a
    reader can check against the code: what the finding misread, or why the cost outweighs it.
  - **Defer**: the problem is real but out of this run's scope. Put it in `notes`.
  The verifiers' low band means "unsure", not "skip", so judge the code, not the band.
- **A moderation finding is not auto-fixed or auto-rejected, primary or appendix.** Whether a
  feature stays, changes or goes is the user's call (`CLAUDE.md`: flag borderline features).
  `AskUserQuestion` with the finding and the options (drop the feature / change it to <allowed
  form> / keep it, dev-only), then fix per the answer.

Fix them:

1. **Group the findings to fix (every primary, plus the appendix ones adjudicated Fix) by
   file**, ordering groups so a module changes before the files that `require` it.
2. Per group, **strictly sequentially**: dispatch a fix agent (the *Fix agent for §5* template,
   `model: implModel`) with the finding text + resolution **inline**. It stages but does **not**
   commit.
3. **Review the staged diff before committing** (`git diff --staged`). Do it yourself for a small
   group; dispatch a `general-purpose` reviewer (`model: reviewModel`) on just that staged diff
   when the group is large or risky (it changes a sliced job, an event handler's state, or runs
   to more than about 200 changed lines). Check:
   - (a) each listed finding is actually resolved;
   - (b) **the fix introduced no new bug**: re-run `review-correctness.md` on the changed lines
     (a nil case, an empty list, a fallback defeated, a guard removed);
   - (c) nothing out of scope changed, and nothing from the `notes`-listed unrelated files was
     staged;
   - (d) **every comment the fix added or rewrote passes Part A of
     `.claude/review-lenses/review-comments.md`**. List them with
     `git diff --staged -U0 | grep -E '^[+][[:space:]]*--'` and check each for narration of the
     change or the old code, finding ids / task labels / commit hashes, and the halving test;
   - (e) **the new code passes the lens that raised the finding** (re-read the changed lines
     against that lens file), and any API call it adds or changes matches the reference;
   - (f) **every suppression the fix added is justified**:
     `git diff --staged -U0 | grep -E '^[+].*(selene: allow|stylua: ignore)'`. A lint firing on
     new code usually means the code is the wrong shape; re-dispatch unless the stated reason
     holds.
   - (g) **a fix to a privacy, moderation or data guard holds against your own probes**: run
     inputs that try to get past it against the staged code from a scratch dir, as §3 step 4
     describes. A fix that closes the reported hole often leaves its neighbour open.

   If it surfaces a problem, re-dispatch the fix agent on the same group with the correction
   before committing. Keep it proportionate: a one-line rename needs only a glance.
4. **Commit the group** (per *Fix commit messages* below), then confirm `scripts/check.sh`
   exits 0 before the next group.

If a finding cannot be fixed without a refactor beyond its own scope, **do not force a bad fix**:
mark it *deferred*, with why, in `notes` and the final report.

Then **re-run §4**; the fixes are code too.

### Fix commit messages

The report is gitignored and never committed, so a finding id (`W1`, `I4`) means nothing to anyone
reading `git log` or blaming the line later. The message must say **what was wrong and why the
code changed** on its own, without the report.

- **Subject**: imperative, in the repo's style, describing the change, not listing ids
  (`Bound var-dump's snapshot pass per tick`). For a group with several unrelated findings, name
  the area and the dominant fix.
- **Body**: one bullet per finding in the group, each stating **the problem** (and its
  consequence in the client) and **the fix** (what the code does now), as plain prose.
- **Ids are optional and never stand alone.** A trailing `(W1)` after a bullet that already
  explains itself is fine; a bullet or subject that is only ids is not.
- End with the commit attribution lines from your own instructions, if any.

```
Slice var-dump's describe step and nil-check request results

- The describe step formatted every listed var in one Logic callback; on a full account that
  ran past the client's 1000 ms limit and the snapshot died half-sent. It now formats at most
  WORK_PER_TICK vars per tick. (W2)
- reportFailure indexed request.errorInfo, which is nil when the request was refused before it
  was sent, so the failure path itself errored. It now logs "unknown" for a missing field. (I3)
```

## 6. Hand back

This skill ends in **reviewed commits on `main`** and a report, not a push or a PR (`CLAUDE.md`
keeps work on `main`, and pushing to the remote is the user's call). Never push, amend, rebase or squash the run's
commits.

After the final §4 passes, write `phase: "done"` to state.json, then give the **final report**:

- What was implemented, per task, with commit SHAs (`git log --oneline "$BASE"..HEAD`).
- What the per-task reviews caught and fixed. Any UNREVIEWED task, by id.
- Code review: primary findings fixed (by id); each appendix finding's adjudication (by id:
  fixed, rejected with the reason, or deferred with why); anything else deferred (with why); and
  the report path.
- The final `scripts/check.sh` result.
- **In-client checks**, as a numbered list the user can follow in the beta client: `prf` if a
  manifest or plugin was added, `prl <name>` (or `pon <name>`), each action from the criteria's
  in-client lines, the expected result, and the plugin's log tag with a grep regex for its lines
  (`CLAUDE.md`: tagged debug logging comes with a regex). **If the bridge is connected, run the
  console half before reporting**: `rsdev.py exec "prf"` / `exec "prl <name>"`, then `shot` and
  `events`. Say what you saw (the overlay is there, an error showed). Leave on the user's list
  only the in-game actions, and run the console and capture side while they do them. If the
  bridge isn't connected, ask the user to `pon dev-bridge` (their one console step) rather than
  handing them console commands.
- Any `**Assumption:**` you made, the moderation tier you placed the feature in, and anything you
  noticed but kept out of scope.

---

## Escape hatch

If, after reading the code, the work needs genuine design decisions or five-plus tasks, **stop
and say so** instead of hand-rolling a migration through a loop built for small changes.
`AskUserQuestion`: proceed anyway under sdd-loop / plan it first / narrow the scope / phase it
into a programme of runs (below).

The trigger is **size and design, not uncertainty**. A handful of ambiguities is §0b doing its
job. The trigger is an ask that needs *competing approaches weighed* rather than *details pinned
down* — a new plugin's architecture, a feature whose guideline tier depends on how it is built —
when the honest answer to "what should this look like?" is a design discussion.

### A programme of runs

When the user's answer is to split the work into phases (infrastructure first, then the
feature, then extensions), each phase is its own sdd-loop **run**, with its own §0 intake,
`BASE`, tasks and §4–§6. What ties them together lives in state.json under `programme`:

- `runs[]`: each run's id, scope and status (`pending` / `active` / `done`), and the intake
  questions already known for a later run, so they are asked at that run's §0 rather than
  forgotten.
- `userDecisions`: the answers that bind every run (also copied into `standingInstructions`).
- `findings`: facts a run established that a later run's intake needs (an in-client probe
  result, a client behaviour), each with where it is recorded in the repo docs.

At §6 of a run, mark it `done` in `programme.runs` and list the next run's open intake
questions in the report. The next run starts with §0 and §1 as usual: a fresh `BASE`,
`tasks` and `phase`, with `programme` and `standingInstructions` carried over. state.json is
gitignored, so a programme that must outlive the checkout also goes into a committed plan
doc, but only if the user asks for one.

When the user asks to try a result in the client before the next task (a checkpoint), record
it in `standingInstructions`, finish the current task's reviews, and wait for their report
before dispatching the next implementer. Fold what they found into the next task's criteria
(and `tasks.json`), so the reviewers check against it.

## Files this skill uses

- `references/dispatch-templates.md`: the Implementer (also the fix agent), Spec-compliance
  reviewer, Code-quality reviewer and §5 fix-agent templates. **Read it before the first
  dispatch** (§3 step 1).
- `.claude/agents/implementer.md`, `.claude/agents/review-verifier.md`: the agent definitions.
- `.claude/workflows/branch-code-review.js`: the §5 review; its lenses are
  `.claude/review-lenses/review-*.md`, and its tests are the `*.test.js` beside it.
- `.claude/skills/durable-state/SKILL.md` and `.claude/hooks/durable-state-resume.sh`: the state
  contract and the resume hook.
- `scripts/check.sh`: the gate.
