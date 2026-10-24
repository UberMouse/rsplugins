---
name: durable-state
description: Keep a run's state in a gitignored JSON file (`.durable-state/state.json`) that survives compaction, a resumed session and handoff, re-surfaced by a SessionStart hook. Use for long or multi-step runs, anything with background agents or workflows in flight, when the user says "track this", "keep state", "remember where we are", "hand off", or before a `/compact`. sdd-loop mixes it in and adds its own fields; it also works standalone.
---

# Durable state

A **mixin**, not a workflow. It gives a run one file that says where the run is, what is still
running, and what the user told you, so that after a compaction or a resume you re-orient from
disk instead of from a lossy summary.

Why it exists: after a `/compact` + "carry on", conductors that kept their state only in context
hand-implemented tasks, dispatched agents without templates or `model`, stopped committing, and
ended turns with nothing running. A file plus a hook that points back at it fixes that; prose
reminders do not.

## When to use

- A run long enough that it may compact, or that may be resumed in a new session.
- Anything with work **in flight**: background agents, workflows, monitors.
- The user asks you to track something across the session, or asks for a handoff.
- A skill you are running says to load this one.

Not for facts git already records (commits, diffs) or scratch that only matters this turn.

## The file

`.durable-state/state.json` at the repo root (the session's cwd, which is what the hook
receives). It is gitignored, so it never lands in a commit. Companion files an owner skill needs
(sdd-loop's `tasks.json`, the branch review's `reviews/`) live in the same directory.

**It is the single source.** No HANDOFF.md / PROGRESS.md / STATE.md beside it. The file records
*where* the run is; git records *what* it did.

**One owner per file.** `skill` names the skill whose §Resuming governs the run. Standalone use
sets `"skill": "durable-state"`. Before writing, check for an existing file: if another skill
owns it and its `phase` is not `done`, don't take it over — put your extra state under a
top-level key you name and leave `skill` alone. A finished run (`phase: "done"`) may be
overwritten by the next one.

## Generic fields

Every field is optional except `skill`. The hook ignores keys it doesn't know, and lists them on
resume so you know to read them.

| Field | Meaning |
|---|---|
| `skill` | owner skill name (a directory under `.claude/skills/`) |
| `sessionId` | the session that owns the run, `$CLAUDE_CODE_SESSION_ID`: written on the first write, and rewritten with your own id on every resume or handoff (the owner is whoever resumed) |
| `phase` | owner-defined string. **`done` is reserved**: the run is finished |
| `goal` | one line: what the run is for. Mostly for standalone use; an owner skill's name usually says it |
| `standingInstructions` | the user's instructions that outlive one turn, **verbatim**, never paraphrased |
| `invariants` | rules of the owner skill that drift after compaction; the hook prints them on every resume |
| `loop` | ≤4 lines: the repeating procedure you are executing |
| `tasks` | `[{id, title, status, …owner fields}]`, `status` ∈ `pending` / `in-progress` / `done` / `blocked-needs-human` / `skipped` |
| `inFlight` | `[{kind: "agent"\|"workflow"\|"monitor", id, what}]`: everything running that will notify you |
| `notes` | `[string]`: facts worth surviving a compaction that fit nowhere else ("the user is testing T01 in the client") |

Owner skills add their own fields (base commit, model tiers, …) as further top-level keys, and
say what they mean.

## Write discipline

1. **Write it before the first thing that can outlive the turn** (a background dispatch, the
   first task), not at the end.
2. **Rewrite it on every transition**: a task dispatched / reviewed / fixed / done; an agent,
   workflow or monitor started or finished; a standing instruction from the user; a phase change.
   Stale state is worse than none: the resume trusts it.
3. **Write atomically**, so a crash never leaves half a file:
   ```bash
   S=.durable-state/state.json
   jq '.phase = "implement"' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
   ```
   The first write:
   `mkdir -p .durable-state && [ -f "$S" ] || jq -n --arg sid "$CLAUDE_CODE_SESSION_ID" '{skill: "<owner>", sessionId: $sid}' > "$S"`.
4. **Set-once fields are read back, never re-derived.** A value captured at the start of the run
   (a base commit) is written once; a resume reads it (`jq -r '.base // empty'`). Re-deriving it
   after work has landed silently changes what "the run" covers.
5. **`inFlight` is a claim.** Add an entry when you dispatch, remove it when its notification
   arrives. `[]` asserts "nothing is running". Omit the field if you aren't tracking background
   work.
6. **`pending` means runnable.** A task blocked on the user is `blocked-needs-human`, and so is
   every task that depends on it, transitively.
7. **Write `phase: "done"` when the run finishes.** A finished run left at another phase makes the
   resume hook re-orient a session that has nothing left to do.

## Resuming — after compaction, a resume, or a handoff

The SessionStart hook `.claude/hooks/durable-state-resume.sh` (matcher `compact|resume`) prints,
when the file exists: a pointer to the owner skill's §Resuming, then a summary: standing
instructions, next task, invariants and in-flight entries first, then phase, goal, base, models,
loop, notes and other keys. It stays under the harness's 2 KB preview: free text is cut to one
line, long lists end in `(N more; Read …)`, and past 1900 bytes the rest is cut with a closing
line saying so. Step 2's full Read is what fills those gaps.

1. **Read the owner skill's §Resuming first**, and every file it names for the recorded phase.
   The harness re-attaches an invoked skill only sometimes, truncated, and never its reference
   files. Whatever you remember about the procedure, re-read it.
2. `Read` the state file in full: the hook's summary omits owner fields. `standingInstructions`
   are the user's words and still bind. Then re-claim it, since you are now the owner:
   `S=.durable-state/state.json; jq --arg sid "$CLAUDE_CODE_SESSION_ID" '.sessionId = $sid' "$S" > "$S.tmp" && mv "$S.tmp" "$S"`.
   Except after a `compact`, which keeps your session id: there a `sessionId` naming another
   session means the run is that session's, not yours: leave the file alone and do not resume it.
3. **Check every `inFlight` entry is still alive.** After a `compact` the process survived and
   background tasks may still be running; after a `resume` (a new process) every one of them is
   gone. Drop dead entries; re-dispatch or resume what they were doing.
4. Continue from the first `in-progress` task, then the first `pending` one.

For standalone use, this section *is* the §Resuming the hook points at.

**Handoff.** When the user asks for one, or says they will `/compact`: rewrite the file now and
give them its absolute path and the owner skill's path. That is the whole handoff.

## The hook

Registered in `.claude/settings.json` (SessionStart, `compact|resume`). Silent when there is no
state file. When `sessionId` names another session, one line saying so instead of the summary;
when it is absent, the summary adds that no owner is recorded. Its table test is
`.claude/hooks/durable-state-resume.selftest.sh`.

## Mixing it into a skill

A skill that keeps durable state:

1. Tells the reader to load this skill (`Read .claude/skills/durable-state/SKILL.md`) before its
   first write, and doesn't restate the generic contract.
2. Names its `skill` value, its `phase` values, and its owner fields with their meaning and when
   they are written.
3. Sets `invariants` for the rules its conductors drift on after compaction.
4. Has a **§Resuming** section (the hook points there) saying which files to Read for each phase,
   plus any owner-specific resume steps.

See `sdd-loop` for a worked example.
