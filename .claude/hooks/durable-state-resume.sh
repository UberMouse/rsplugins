#!/usr/bin/env bash
# SessionStart (matcher `compact|resume`): re-orient a session that keeps durable state
# (`.claude/skills/durable-state/SKILL.md`) after compaction or a resumed session.
#
# The harness re-attaches an invoked skill only on some compaction boundaries, truncates it when
# it does, and never re-attaches the reference files a skill tells the model to Read (sdd-loop's
# dispatch templates). Without a pointer back, a conductor that compacted mid-run implements
# tasks itself and dispatches agents without templates or `model`. So on every compact/resume
# this prints that pointer plus a summary of `<cwd>/.durable-state/state.json`.
#
# No state file (or no/garbled payload) -> print nothing, exit 0: a SessionStart hook must never
# get in the way of a session that keeps no state.

hook_input=$(cat)
cwd=$(jq -r '.cwd // ""' <<<"$hook_input" 2>/dev/null) || exit 0
[[ -n "$cwd" ]] || exit 0

# A compacting subagent fires SessionStart with the parent's session id, and this text is the
# conductor's: an implementer that got it was told to resume the run as conductor. The main
# session's SessionStart carries `agent_type=claude` (logged since 2026-10-29), so only a non-empty
# `agent_id` or an `agent_type` other than `claude` (a subagent, or a `claude --agent` session,
# which doesn't conduct runs here) means "not the conductor".
agent_id=$(jq -r '.agent_id // ""' <<<"$hook_input" 2>/dev/null)
agent_type=$(jq -r '.agent_type // ""' <<<"$hook_input" 2>/dev/null)

# Debug evidence for that guard: which fields a SessionStart actually carries, one tagged line per
# firing in a checkout that keeps durable state (grep: \[DSHOOK\]). Delete this once a subagent's
# compaction has been logged and the guard confirmed.
if [[ -d "$cwd/.durable-state" ]]; then
  printf '[DSHOOK] %s source=%s agent_id=%s agent_type=%s keys=%s\n' \
    "$(date -u +%FT%TZ)" "$(jq -r '.source // ""' <<<"$hook_input" 2>/dev/null)" \
    "$agent_id" "$agent_type" "$(jq -c 'keys' <<<"$hook_input" 2>/dev/null)" \
    >>"$cwd/.durable-state/hook-payloads.log" 2>/dev/null || true
fi

[[ -z "$agent_id" && ( -z "$agent_type" || "$agent_type" == claude ) ]] || exit 0

state="$cwd/.durable-state/state.json"
[[ -f "$state" ]] || exit 0

# Point at the owner skill only if it exists; anything else (missing, garbled, a path) gets the
# generic skill, whose §Resuming works for any owner.
skill=$(jq -r '.skill // ""' "$state" 2>/dev/null)
if ! [[ "$skill" =~ ^[a-z0-9][a-z0-9-]*$ && -f "$cwd/.claude/skills/$skill/SKILL.md" ]]; then
  skill=durable-state
fi

session_id=$(jq -r '.session_id // ""' <<<"$hook_input" 2>/dev/null)
source=$(jq -r '.source // ""' <<<"$hook_input" 2>/dev/null)

# The run's owning session (`sessionId`). Another session that opens this checkout must not be
# pointed at the owner's run. A compact keeps the session id, so there another id settles it; a
# resume may continue under a new id, so it may still be this session's run, handed over.
owner=$(jq -r '.sessionId | if type == "string" then . else "" end' "$state" 2>/dev/null) || owner="?"
if [[ -n "$owner" && "$owner" != "?" && -n "$session_id" && "$owner" != "$session_id" ]]; then
  if [[ "$source" == "compact" ]]; then
    printf 'Durable-state note: another session owns the %s run here (%s names it in sessionId); it is not yours to resume.\n' \
      "$skill" "$state"
  else
    printf 'Durable-state note: another session owns the %s run here (%s names it in sessionId); resume it only if it is your own run under a new session id (a handoff), per .claude/skills/durable-state/SKILL.md §Resuming.\n' \
      "$skill" "$state"
  fi
  exit 0
fi

# Past ~2 KB the harness persists hook output to a file and shows only a preview, which nobody
# opens. What the resume acts on is printed first, so the last resort is to cut the descriptive
# tail at a line boundary. Bytes, not characters (LC_ALL=C), because the preview is in bytes.
resume_budget() {
  LC_ALL=C awk -v max=1900 '
    cut { next }
    { used += length($0) + 1 }
    used > max { print "  (output cut at the 2 KB preview; Read state.json for the rest)"; cut = 1; next }
    { print }'
}

{
printf 'You are running the %s skill. Before any other tool call: Read .claude/skills/%s/SKILL.md §Resuming and every file it names for your phase, then %s\n\n' \
  "$skill" "$skill" "$state"
if [[ -z "$owner" ]]; then
  printf 'This run has no owning session recorded (no sessionId): claim it per .claude/skills/durable-state/SKILL.md §Resuming step 2 only if it is yours.\n\n'
fi

# Only fields that are present are printed. Every free-text field is cut to one bounded line and
# every list to a few entries; `cap` flattens control characters so a newline in a value cannot
# print a line that reads like one of these. An in-progress task outranks the first pending one.
if ! summary=$(jq -r '
  def known: ["skill","sessionId","phase","goal","branch","base","implModel","reviewModel",
              "tasks","inFlight","standingInstructions","invariants","loop","notes"];
  def cap($n): (if type == "string" then . else tojson end)
    | gsub("[\\x00-\\x1f\\x7f\\x{80}-\\x{9f}\\x{2028}\\x{2029}]+"; " ") | sub("^ +"; "") | sub(" +$"; "")
    | if length > $n then .[0:$n] + "… (cut; Read state.json)" else . end;
  def some($n; $prefix; f): (.[0:$n][] | "\($prefix)\(f)"),
    (if length > $n then "\($prefix)(\(length - $n) more; Read state.json)" else empty end);
  def arr: if type == "array" then . else [] end;
  ([(.tasks | arr)[] | select(.status == "in-progress")] + [(.tasks | arr)[] | select(.status == "pending")] | first) as $next |
  "Durable state (from state.json):",
  (if (.standingInstructions | arr | length) > 0 then "  standing user instructions (verbatim):",
     (.standingInstructions | arr | some(6; "    > "; cap(240))) else empty end),
  (if (.tasks | arr | length) == 0 then empty
   elif $next then "  next task: \($next.id | cap(40)) \($next.title // "" | cap(120)) [\($next.status)]" + (if $next.agentInFlight then " — agent in flight: \($next.agentInFlight | cap(60))" else "" end)
   else "  next task: none pending" end),
  (if (.invariants | arr | length) > 0 then "  invariants of the \(.skill // "owner" | cap(40)) skill:",
     (.invariants | arr | some(8; "    - "; cap(300))) else empty end),
  (if (.inFlight | arr | length) > 0 then "  in flight before the boundary (check each is still alive):",
     (.inFlight | arr | some(6; "    - "; "\(.kind | cap(20)) \(.id | cap(60)): \(.what // "" | cap(150))")) else empty end),
  "  phase: \(.phase // "unknown" | cap(60))",
  (if .goal then "  goal: \(.goal | cap(200))" else empty end),
  (if .branch or .base then "  branch: \(.branch // "unknown" | cap(100))  base: \(.base // "unknown" | cap(60))" else empty end),
  (if .implModel or .reviewModel then "  implModel: \(.implModel // "unset" | cap(40))  reviewModel: \(.reviewModel // "unset" | cap(40))" else empty end),
  (if .loop then "  loop: \(.loop | cap(200))" else empty end),
  (if (.notes | arr | length) > 0 then "  notes:", (.notes | arr | some(3; "    - "; cap(160))) else empty end),
  ([keys[] | select(. as $k | known | index($k) | not)] as $other |
   if ($other | length) > 0 then "  other keys (Read state.json for them): \($other | join(", ") | cap(300))" else empty end)
' "$state" 2>/dev/null); then
  printf 'state.json did not parse — Read it directly before continuing.\n'
  exit 0
fi
printf '%s\n' "$summary"
} | resume_budget
exit 0
