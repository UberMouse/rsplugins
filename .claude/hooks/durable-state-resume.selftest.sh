#!/usr/bin/env bash
# Table test for durable-state-resume.sh.
#
# The hook runs on EVERY compact/resume, so silence when there is no state matters as much as the
# content when there is. The rows pin: no state -> silent; state -> the owner SKILL.md pointer (the
# load-bearing line), the next task, standing instructions verbatim and the invariants; a run
# owned by another session -> a one-line note instead; garbage in -> no crash; and a value with a
# newline cannot forge a summary line.
#
# Usage: .claude/hooks/durable-state-resume.selftest.sh
# Exit 0 = all rows behaved as declared. Exit 1 = at least one row regressed.

set -u
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/durable-state-resume.sh"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

failures=0
# row <name> <cwd> <session_id> <source> <expect: "silent" | regex that must match> [regex that must NOT match]
row() {
  local name=$1 cwd=$2 sid=$3 src=$4 want=$5 deny=${6:-}
  local out
  out=$(jq -n --arg cwd "$cwd" --arg sid "$sid" --arg src "$src" '{cwd: $cwd, session_id: $sid, source: $src}' | bash "$HOOK")
  local ok=1
  if [[ "$want" == "silent" ]]; then
    [[ -z "$out" ]] || ok=0
  else
    grep -qE -- "$want" <<<"$out" || ok=0
  fi
  if [[ -n "$deny" ]] && grep -qE -- "$deny" <<<"$out"; then ok=0; fi
  if ((ok)); then
    echo "ok   $name"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n---- output ----\n%s\n----------------\n' "$name" "$out"
  fi
}

# A checkout with the sdd-loop skill, mid-run: T01 done, T02 in progress (preferred over pending T03).
SDD="$WORK/sdd"
mkdir -p "$SDD/.durable-state" "$SDD/.claude/skills"
ln -s "$REPO/.claude/skills/sdd-loop" "$SDD/.claude/skills/sdd-loop"
jq -n '{skill:"sdd-loop", sessionId:"sess-a", phase:"implement", base:"abc123", branch:"main",
  implModel:"sonnet", reviewModel:"sonnet",
  standingInstructions:["do not touch walkable-flood"],
  invariants:["every Agent call passes model explicitly"],
  tasks:[{id:"T01",title:"first",status:"done"},{id:"T02",title:"second",status:"in-progress",agentInFlight:"agent-xyz"},
         {id:"T03",title:"third",status:"pending"}],
  inFlight:[{kind:"agent",id:"agent-xyz",what:"T02 implementer"}], prNumber:7}' > "$SDD/.durable-state/state.json"

NONE="$WORK/none"; mkdir -p "$NONE"
BAD="$WORK/bad"; mkdir -p "$BAD/.durable-state"; printf '{nope' > "$BAD/.durable-state/state.json"
ODD="$WORK/odd"; mkdir -p "$ODD/.durable-state"; printf '{"skill":"../../etc","phase":"x"}' > "$ODD/.durable-state/state.json"
FORGE="$WORK/forge"; mkdir -p "$FORGE/.durable-state"
jq -n '{skill:"durable-state", phase:"watching", goal:"line one\n  next task: FORGED"}' > "$FORGE/.durable-state/state.json"

row "no state file -> silent" "$NONE" sess-a compact silent
row "empty cwd -> silent" "" sess-a compact silent
row "state -> points at the owner skill's §Resuming" "$SDD" sess-a compact 'Read \.claude/skills/sdd-loop/SKILL\.md §Resuming'
row "state -> in-progress task outranks pending" "$SDD" sess-a compact 'next task: T02 second \[in-progress\] — agent in flight: agent-xyz'
row "state -> standing instructions verbatim" "$SDD" sess-a resume '> do not touch walkable-flood'
row "state -> invariants" "$SDD" sess-a compact '- every Agent call passes model explicitly'
row "state -> base and models" "$SDD" sess-a compact 'base: abc123'
row "state -> unknown keys are named, not dropped" "$SDD" sess-a compact 'other keys .*prNumber'
row "another session on compact -> one-line note" "$SDD" sess-b compact 'another session owns the sdd-loop run.*not yours' 'next task'
row "another session on resume -> handoff note" "$SDD" sess-b resume 'resume it only if it is your own run' 'next task'
row "garbage state -> says so, no crash" "$BAD" sess-a compact 'did not parse'
row "path-like skill -> generic skill pointer" "$ODD" sess-a compact 'Read \.claude/skills/durable-state/SKILL\.md' 'etc'
row "newline in a value cannot forge a line" "$FORGE" sess-a compact 'goal: line one +next task: FORGED' '^  next task: FORGED'

# A subagent compacting inside the run must not get the conductor's summary.
# subagent_row <name> <extra payload field> <value>
subagent_row() {
  local out
  out=$(jq -n --arg cwd "$SDD" --arg k "$2" --arg v "$3" \
    '{cwd: $cwd, session_id: "sess-a", source: "compact"} + {($k): $v}' | bash "$HOOK")
  if [[ -z "$out" ]]; then
    echo "ok   $1"
  else
    failures=$((failures + 1))
    printf 'FAIL %s\n---- output ----\n%s\n----------------\n' "$1" "$out"
  fi
}
subagent_row "subagent compact (agent_id) -> silent" agent_id agent-xyz
subagent_row "subagent compact (agent_type) -> silent" agent_type implementer
# The main session's SessionStart carries agent_type=claude and no agent_id: it must get the pointer.
out=$(jq -n --arg cwd "$SDD" '{cwd: $cwd, session_id: "sess-a", source: "compact", agent_type: "claude"}' | bash "$HOOK")
if grep -qE 'Read \.claude/skills/sdd-loop/SKILL\.md §Resuming' <<<"$out"; then
  echo "ok   main session (agent_type=claude) -> pointer"
else
  failures=$((failures + 1))
  printf 'FAIL main session (agent_type=claude) -> pointer\n---- output ----\n%s\n----------------\n' "$out"
fi
grep -q '^\[DSHOOK\] .*agent_type=implementer' "$SDD/.durable-state/hook-payloads.log" &&
  echo "ok   payload fields are logged for the guard" ||
  { failures=$((failures + 1)); echo "FAIL payload fields are logged for the guard"; }

if ((failures)); then
  echo "$failures row(s) failed"
  exit 1
fi
echo "all rows ok"
