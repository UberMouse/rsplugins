export const meta = {
  name: 'branch-code-review',
  description: 'Code review of the commits BASE..HEAD (PURE compute): 7 parallel finders (correctness, RS API & runtime limits, architecture, cleanup, comments, moderation, and an API-grounding lens that checks every API use against the developer.runescape.com search index), a RECALL-FIRST verify pass (findings grouped by lens + folder, up to 6 per verifier, each verifier picks a band A-D from its lens calibration) that drops only factually-wrong findings and DEMOTES (never deletes) low-confidence ones into an appendix, and a deduplicated, id-keyed markdown report plus a structured findingsList. The lens criteria live in .claude/review-lenses/review-*.md; edit them there, not in this script. The sdd-loop skill (§5) is the conductor that fixes the primary findings.',
  whenToUse: 'Review a range of commits on main. Usually invoked by sdd-loop §5; can also be run standalone for a report-only review. args: { base?: commit-ish the review starts from (exclusive; default: `base` in .durable-state/state.json; e.g. "HEAD~3" or a sha), effort?: "low"|"medium"|"high"|"max" (default medium = deep reading + recall-first verify; scales verify votes + main-report band + finder depth + verify model), repoPath?: absolute path of the checkout to review (default: the session cwd), focus?: free text from the requester handed to every finder and reported back per lens }. Returns { reportPath, reportWritten, findingsList, branch, base, head, effort, filesChanged, incomplete, coverage, findings, primary, appendix, critical, warning, info } (or { skipped, reason }). Each finding carries a `tier` ("primary" | "appendix"). FAIL-CLOSED: `incomplete: true` means an applicable finder lens (or the synthesis) died even after retry — coverage.failed lists the unreviewed lenses and the findings are PARTIAL (resume the runId once the failure cause clears; completed lenses cache-hit).',
  phases: [
    { title: 'Gather', detail: 'one haiku agent resolves BASE..HEAD, the changed files and plugins, per-file counts of added comment blocks (the comments finder\'s checklist), and a local copy of the API search index for the grounding lens' },
    { title: 'Review', detail: '7 finders (correctness, rs-api, architecture, cleanup, comments, moderation, api-grounding), sonnet; criteria read from .claude/review-lenses/review-*.md' },
    { title: 'Verify', detail: 'recall-first, grouped: each lens\'s findings packed by folder into groups of up to 6, one review-verifier per group per vote round, up to effort.votes rounds (a finding leaves once later votes cannot change its outcome), each finding banded A-D against its lens calibration, primary by vote; drop only refuted findings, demote low-confidence to appendix, sonnet' },
    { title: 'Report', detail: 'one sonnet agent dedupes + writes the id-keyed markdown report' },
  ],
}

// ---- effort knob -----------------------------------------------------------
// RECALL-FIRST tuning: the review is biased toward catching real issues over minimizing false
// positives, because a dropped real finding costs more than an appendix entry someone skims.
// votes        = the most verdicts a finding gets, one per vote round (see voteDecided). A
//                finding is DROPPED only if a MAJORITY of votes mark it refuted=true (i.e.
//                factually wrong); a round is skipped for a finding whose outcome it cannot
//                change.
// primaryBand  = the lowest verifier band (A-D, see BAND_SCORE) that puts a finding in the
//                MAIN report; below it a finding is NOT deleted — it is DEMOTED to a
//                "Worth a Look" appendix (default Resolution: Skip).
// depth        = finder reading discipline. `deep` makes finders trace callers, events and
//                callbacks instead of reading the diff in isolation, which is where runtime bugs
//                hide.
// verifyModel  = model that adjudicates findings. NOT haiku at the default: a weak verifier
//                refutes subtle correctness findings it can't follow.
const EFFORT = {
  low:    { votes: 1, primaryBand: "B", depth: "shallow", verifyModel: "haiku"  },
  medium: { votes: 2, primaryBand: "B", depth: "deep",    verifyModel: "sonnet" },
  high:   { votes: 2, primaryBand: "C", depth: "deep",    verifyModel: "sonnet" },
  max:    { votes: 3, primaryBand: "C", depth: "deep",    verifyModel: "sonnet" },
}
// args may arrive as an object or as a JSON-encoded string depending on the
// caller — normalize to an object. A bare string is treated as the effort name.
let A = args
if (typeof A === "string") {
  try { A = JSON.parse(A) } catch (e) { A = { effort: A } }
}
A = A && typeof A === "object" ? A : {}

// A verifier's fixed cost (lens file, diff, surrounding code) dwarfs the marginal cost of one more
// finding in code it has already read, so a lens's findings are verified in groups drawn from the
// same or neighbouring folders. Past ~6 a verifier starts skimming the tail.
const VERIFY_GROUP_MAX = 6
// .claude/agents/review-verifier.md: read-only, and no CLAUDE.md in its prompt. Verifiers read the
// conventions lens instead.
const VERIFIER_AGENT = "review-verifier"

const effortName = A.effort || "medium"
const effort = EFFORT[effortName] || EFFORT.medium

// Optional: review a checkout other than the session cwd.
const REPO = A.repoPath || null
const G = REPO ? `git -C "${REPO}"` : "git"
const REPO_NOTE = REPO
  ? `The repository to review is at ${REPO}. Prefix every git command with \`git -C "${REPO}"\` and read source files under ${REPO}/<path>.\n`
  : ""

// The review's start commit. On main there is no merge-base to diff against, so the caller names
// it, or the gather step reads the run's `base` from .durable-state/state.json. Sanitised because
// it is interpolated into a shell command: a commit-ish only needs [A-Za-z0-9._/~^-].
const BASE_ARG = /^[A-Za-z0-9._/~^-]+$/.test(A.base || "") ? A.base : ""

// Free text from the requester, handed to every finder. Prompt text only, never a shell arg.
const FOCUS = typeof A.focus === "string" ? A.focus.trim() : ""

const API_INDEX_URL = "https://developer.runescape.com/rs/search.json"

// ---- schemas ---------------------------------------------------------------
const GATHER_SCHEMA = {
  type: "object",
  properties: {
    eligible: { type: "boolean" },
    skipReason: { type: "string" },
    branch: { type: "string" },
    mergeBase: { type: "string" },
    mergeBaseShort: { type: "string" },
    headShort: { type: "string" },
    repoRoot: { type: "string" },
    files: { type: "array", items: { type: "string" } },
    plugins: { type: "array", items: { type: "string" } },
    fileCount: { type: "number" },
    // "path:N" per file — how many COMMENT_AWK checklist items that file has. Counts, not the
    // items: a large diff can add hundreds of comment blocks, and a list that size is rejected or
    // silently thinned by a structured return. Each comments finder regenerates its own items
    // with the same awk and is checked against these counts.
    commentBlockCounts: { type: "array", items: { type: "string" } },
    // Absolute path of the local API search index copy; "" when the fetch failed (the grounding
    // finder then fetches it itself).
    apiIndexPath: { type: "string" },
  },
  required: ["eligible", "branch", "files", "fileCount", "commentBlockCounts"],
}

const FINDINGS_SCHEMA = {
  type: "object",
  properties: {
    applicable: { type: "boolean" },
    naReason: { type: "string" },
    findings: {
      type: "array",
      items: {
        type: "object",
        properties: {
          severity: { type: "string", enum: ["critical", "warning", "info"] },
          file: { type: "string" },
          // Models emit line numbers as integers or strings; accept both so a numeric `line`
          // doesn't fail schema validation and force a full extra finder turn.
          line: { type: ["string", "number"] },
          part: { type: "string" },
          summary: { type: "string" },
          snippet: { type: "string" },
          suggestion: { type: "string" },
        },
        required: ["severity", "file", "summary"],
      },
    },
    // Comments finder only: one entry per COMMENT CHECKLIST item (path:start-end).
    commentChecklist: {
      type: "array",
      items: {
        type: "object",
        properties: {
          item: { type: "string", description: "path:start-end, as the checklist command printed it" },
          verdict: { type: "string", enum: ["finding", "passes"] },
          why: { type: "string" },
        },
        required: ["item", "verdict", "why"],
      },
    },
    // Set only when the run has a USER FOCUS: what this lens checked for it, with counts.
    focusReport: { type: "string" },
    // In-scope files the finder admits it never read — surfaced in coverage, not hidden.
    unreachedFiles: { type: "array", items: { type: "string" } },
  },
  required: ["applicable", "findings"],
}

// Verify verdicts are parsed IN-SCRIPT rather than forced through StructuredOutput. Models
// routinely (a) double-wrap the whole payload as a JSON string under a lone `input` key and (b)
// omit a required field — both of which the tool-layer validator rejects, costing a full extra
// inference turn per miss. Parsing leniently here recovers those turns: unwrap the `input`
// envelope, coerce types, and default missing fields the recall-first way (refuted=false keeps
// the finding; band D routes it to the appendix). A verdict missing for a finding is treated as a
// dead vote on that finding (it survives as appendix, never silently lost).
// ---- verdict parsing

// Verifiers pick a lens BAND rather than a number. Free 0-100 scores piled up just under the
// main-report cutoff: verifiers quoted their lens's worth-fixing clause and then discounted it
// for "minor". A band is a claim about which lens clause the finding meets, and the number is
// derived here, so there is no gap left to land in.
const BAND_SCORE = { A: 90, B: 72, C: 50, D: 20 }

function bandOf(obj) {
  // The whole value must be a band ("B", "band B", "B — clause"): a first-letter match would
  // read a malformed "broken" as B and put it in the main report.
  const m = String(obj.band || "").trim().match(/^(?:band\s*)?([ABCD])(?![A-Za-z])/i)
  if (m) return m[1].toUpperCase()
  // An off-schema answer that still gave a number is mapped onto the band it would sit in.
  const n = typeof obj.confidence === "number" ? obj.confidence : Number(obj.confidence)
  if (obj.confidence != null && obj.confidence !== "" && Number.isFinite(n)) {
    return n >= 85 ? "A" : n >= 65 ? "B" : n >= 40 ? "C" : "D"
  }
  return "D"
}
function extractJson(raw) {
  if (raw == null) return null
  let text = typeof raw === "string" ? raw : JSON.stringify(raw)
  const fence = text.match(/```(?:json)?\s*([\s\S]*?)```/i)
  if (fence) text = fence[1]
  // A bare array is a legal answer too; take whichever bracket opens first.
  const ob = text.indexOf("{")
  const ab = text.indexOf("[")
  const isArray = ab !== -1 && (ob === -1 || ab < ob)
  const start = isArray ? ab : ob
  const end = text.lastIndexOf(isArray ? "]" : "}")
  if (start === -1 || end <= start) return null
  let obj
  try {
    obj = JSON.parse(text.slice(start, end + 1))
  } catch {
    return null
  }
  // Unwrap the `{ input: "{...}" }` double-wrap when it appears.
  if (obj && !Array.isArray(obj) && typeof obj.input === "string" && obj.verdicts === undefined && obj.refuted === undefined) {
    try {
      obj = JSON.parse(obj.input)
    } catch {
      // fall through and use whatever the outer object gave us
    }
  }
  return obj && typeof obj === "object" ? obj : null
}

function normVerdict(obj) {
  if (!obj || typeof obj !== "object") return null
  const refuted = obj.refuted === true || obj.refuted === "true"
  const band = bandOf(obj)
  return {
    refuted,
    band,
    confidence: refuted ? 0 : BAND_SCORE[band],
    matched: typeof obj.matched === "string" ? obj.matched : "",
    reasoning: typeof obj.reasoning === "string" ? obj.reasoning : "",
  }
}

// PURE: one group verifier's answer -> { [key]: verdict | null } for every key it was asked.
// Accepts `{ verdicts: [...] }`, a bare array, or an object keyed by finding key. Entries are
// matched on `key` (or `id`); a keyless list is matched by position only when its length
// equals the group's, since a short positional list cannot say which finding it skipped.
function parseVerdicts(raw, keys) {
  const out = Object.fromEntries(keys.map((k) => [k, null]))
  const obj = extractJson(raw)
  if (!obj) return out
  const list = Array.isArray(obj) ? obj : Array.isArray(obj.verdicts) ? obj.verdicts : null
  if (!list) {
    for (const k of keys) out[k] = normVerdict(obj[k])
    return out
  }
  const keyOf = (e) => String((e && (e.key ?? e.id)) ?? "").trim()
  const positional = list.length === keys.length && list.every((e) => !keyOf(e))
  list.forEach((e, i) => {
    const k = positional ? keys[i] : keyOf(e)
    if (k in out && !out[k]) out[k] = normVerdict(e)
  })
  return out
}

const SYNTH_SCHEMA = {
  type: "object",
  properties: {
    reportPath: { type: "string" },
    // Workflow scripts cannot stat a file, so the agent has to say whether its write landed;
    // otherwise a refused write still returns a reportPath that does not exist.
    reportWritten: { type: "boolean" },
    critical: { type: "number" },
    warning: { type: "number" },
    info: { type: "number" },
  },
  required: ["reportPath", "reportWritten"],
}

// ---- shared review lenses --------------------------------------------------
// The lens CRITERIA are deliberately NOT inline here. They live in .claude/review-lenses/ so the
// finders, the verifiers and the fix agents all read the same text. What stays here is the
// workflow PROTOCOL — reading depth, applicability, output schema — plus the pointer to each lens.
//
// A `focus` string therefore states SCOPE and APPLICABILITY only, and may say which Parts of its
// lens reach beyond the diff (that is a research instruction, not a criterion). It must never
// restate, summarise, or add a criterion or a severity: a paraphrase here drifts from the lens
// file and reads to the finder as a complete statement of the bar. Add criteria to the lens file.
//
// review-conventions.md holds the cross-lens policy every finder needs (severity calibration,
// consequence tracing, pattern-consistency sweeps, what scripts/check.sh already catches).
//
// A `scoring` string is VERIFY protocol, not a criterion: it defines the lens's bands A-D (which
// decide main report vs appendix, see BAND_SCORE) in examples from its own lens. Name findings by
// their Part and say what the verifier must have confirmed for each band; never add a new thing
// to look for. A band's text already prices in impact and likelihood, so write any condition that
// should lower a finding (rare trigger, dev-only plugin) into the band it belongs in: the verifier
// is told not to discount a met band for reasons the band does not name.
//
// Workflow scripts have no filesystem access, so the read happens inside the FINDER agent. It is
// mandatory and FAIL-LOUD: a finder that cannot read its lens must report that as a critical
// finding rather than reviewing from memory, because a silently-empty lens is indistinguishable
// from a clean review.
const LENS_DIR = ".claude/review-lenses"
const CONVENTIONS_LENS = "review-conventions.md"

function lensFiles(dim) {
  return [CONVENTIONS_LENS, dim.lensFile].filter(Boolean)
}

function lensReadCommands(dim) {
  return lensFiles(dim).map((f) => `  cat "${REPO ? REPO + "/" : ""}${LENS_DIR}/${f}"`)
}

function lensBlock(dim) {
  return [
    "REVIEW LENS FILES (MANDATORY — read these FIRST, before you read the diff):",
    ...lensReadCommands(dim),
    "They are the single source of truth for this review's criteria and severity scale. Apply EVERY criterion in them.",
    "Work each lens STRUCTURALLY rather than from your memory of what a lens of this kind usually " +
      "asks. Every Part is in scope, and within a Part every discrete criterion is a SEPARATE check " +
      "to run against every candidate — whatever form that lens writes them in: a bolded question, a " +
      "numbered or bulleted item, or one clause of a prose list. Enumerate them before you judge " +
      "anything, and carry the whole set past each candidate: passing one criterion never clears an " +
      "item of the others. The FOCUS below narrows scope and states applicability only — it is " +
      "deliberately not a summary of the criteria, so never treat it as the list.",
    'If you cannot read a lens file, do NOT review from memory: return applicable=true with a single ' +
      'critical finding summarised "review lens unavailable: <file>", so the run is not mistaken for a clean review.',
    "SCOPE: review every changed file your FOCUS covers, new files included. Never narrow your own scope " +
      "(a `--diff-filter=M`, reading the first part of a listing and stopping). If the diff is too large to " +
      "read in full, list the files you did not reach in unreachedFiles rather than returning as though you had.",
  ].join("\n")
}

const DEPTH_TEXT = {
  shallow:
    "DEPTH: high-signal scan. Surface clear, high-impact issues. Ignore pure formatting and " +
    "anything scripts/check.sh rejects. Read a file's full context (and the callers of anything " +
    "that changed) when you need it to confirm a finding or its consequence — do not report from the " +
    "raw diff alone.",
  deep:
    "DEPTH: deep review. The diff alone is not enough. For every relevant changed file: read the " +
    "FULL source file (not just changed lines); read the rest of the plugin for its local conventions; " +
    "trace callers and events (if a function's arguments or returns changed, find every caller; if a " +
    "callback changed, find the event that fires it and what state it shares with other callbacks; " +
    "if a module changed, find every require of it). Verify every claim against the actual code " +
    "before reporting — never report from the diff alone. You MAY include plausible-but-uncertain " +
    "findings — the verify pass DEMOTES rather than deletes them, so do not self-censor a " +
    "real-but-arguable issue.",
}

const DIMENSIONS = [
  {
    key: "correctness",
    label: "Correctness & Data Flow",
    model: "sonnet",
    lensFile: "review-correctness.md",
    scoring:
`Score by how much of the triggering path you CONFIRMED, not by how bad the bug would be if it happened.
A — you found the event, caller or input that delivers the bad value, and it errors the callback, freezes or crashes the client, or loses saved data.
B — the path is reachable but the effect degrades rather than breaks (an overlay stale until the next recompute, a value wrong after a reload, a missed entity), or the trigger is real but uncommon (logged out, an empty list, an instance, the first enable).
C — wrong in isolation, but every current caller guards it upstream or you could not find an input that reaches it: latent, it bites the next caller.
D — the premise needs an input the API reference rules out (a documented non-nil return, a fixed value range), or an ordering with no plausible trigger.`,
    focus:
`FOCUS — runtime correctness via DATA-FLOW tracing (criteria: review-correctness.md).
Part A nil and missing values, Part B Lua semantics, Part C state across ticks, events and reloads, Part D error handling.
This dimension is applicable whenever any Lua, Python or shell logic changed — only set applicable=false for pure docs/config diffs.`,
  },
  {
    key: "rsapi",
    label: "RS API & Runtime Limits",
    model: "sonnet",
    lensFile: "review-rs-api.md",
    pluginOnly: true,
    scoring:
`A — a Part A limit hit on a realistic path you traced (a loop whose worst case in a busy area you can show runs past 1000 ms in one call; an HTTP request started from a completion callback); a Part B lifecycle hook declared local, or a subscription-name collision that drops a live handler; a Part C component that never draws on a path the feature needs.
B — a Part B contract misread with a visible effect on an edge case (no startup scan for an *Added-driven feature, a revoked permission not handled, missing teardown on toggle); Part D requiredPermissions, an undeclared or hard-coded URL, or PersistentDB written every tick; Part A per-frame work that could run once per change.
C — cost or lifecycle concerns with no realistic trigger today (a loop that is bounded small in practice); Part E dev-only API in a plugin not marked for submission either way.
D — the finding assumes a client behaviour neither docs/ nor the reference states, and you could not confirm it.`,
    focus:
`FOCUS — how the change uses the plugin API and lives within the client's runtime limits (criteria: review-rs-api.md).
Part A runtime limits, Part B events and lifecycle, Part C UI, Part D manifest/permissions/storage/modules, Part E dev-only API.
Parts A and B reach beyond the diff: a changed callback is judged with every other callback and tick job in its plugin, so read the whole plugin.`,
  },
  {
    key: "architecture",
    label: "Architecture & Structure",
    model: "sonnet",
    lensFile: "review-architecture.md",
    scoring:
`Score duplication and structure findings by whether you found BOTH sides: the other copy, or the shell call inside the core.
A — duplicated logic whose copies have ALREADY diverged into a bug; a plugin-wide mutable global two modules write; a core function calling the shell in a way that already misbehaves.
B — verified duplication of non-trivial logic (you found the other copy; the next fix will land in only one); API calls threaded through logic that could be pure; a second way of doing something the plugin already has a pattern for (name the existing one); a module relying on require order; a house convention CLAUDE.md names — these are band B.
C — fit, naming or placement that differs from the rest of the plugin; overengineering whose cost is only readability; a record-shape inconsistency no reader trips on yet.
D — snippets that differ enough to justify separate copies; duplication across independent plugins with no shared dependency; duplication you could not locate the second copy of.`,
    focus:
`FOCUS — architecture, duplication and module structure (criteria: review-architecture.md).
Part A duplication, Part B architecture, Part C data shapes, Part D house conventions (return-type annotations).
Parts A and B reach beyond the diff: both are judged against the rest of the plugin, so read its other files, not just the changed lines.`,
  },
  {
    key: "cleanup",
    label: "Reuse / Simplification / Efficiency",
    model: "sonnet",
    lensFile: "review-cleanup.md",
    scoring:
`These are quality findings, not bugs: score how sure you are that the suggested form is correct AND better. Check the replacement, not just the complaint.
A — rare: repeated work with a real cost in Draw or a per-tick handler (a list query per entity per frame, O(n²) over tiles or locs); dead code the change itself added.
B — a Part A reimplementation where you FOUND the existing helper, stdlib or API function and confirmed it is a drop-in (same nil, empty-table and integer/float behaviour); a Part B redundant branch or simplification whose replacement you checked preserves behaviour.
C — a readability win reasonable people could decline; efficiency on a once-at-enable path; logic at the wrong layer that works.
D — the "existing helper" differs in semantics so it is not a drop-in; micro-optimisation; taste; a terser form a moderator would find harder to read.`,
    focus:
`FOCUS — reuse, simplification and efficiency cleanups (criteria: review-cleanup.md).
Part A reuse, Part B simplification, Part C efficiency & altitude.
Part A reaches beyond the diff: it is judged against the plugin's own helpers, the Lua standard library and the plugin API, so search for an existing one before calling code a reimplementation.`,
  },
  {
    key: "comments",
    label: "Comments",
    model: "sonnet",
    lensFile: "review-comments.md",
    commentChecklist: true,
    scoring:
`A comment's consequence falls on the next reader and on the moderator. Every Part A test is a written rule, so a verified breach is main-report material, not style.
A — a Part B stale comment that, if followed, reintroduces a freeze, crash or data loss; a plugin header or README describing keys or behaviour the change replaced.
B — a verified breach of a Part A test: restates the WHAT, fails stand-alone (plan or review labels, session references, an unnamed prior state), narrates an intermediate state of the change, misdescribes its code or the API, or fails the halving test with a suggested replacement that keeps every reason a reader could act on; a Part B stale, orphaned, narrowed or widened comment; a suppression whose stated reason no longer holds; a new plugin with no header comment.
C — a halving-test failure whose suggested replacement drops a constraint or reason (say what it lost); a Part C missing comment on genuinely non-obvious code.
D — a long comment where every line carries a distinct actionable reason; a Part C request for a comment on code a reader can follow unaided.`,
    focus:
`FOCUS — comments as long-lived documentation for the next author and the moderator (criteria: review-comments.md).
Part A added comments, Part B EXISTING comments in modified code (including the plugin header and README), Part C genuinely missing comments.
Part B reaches beyond the diff: it scopes to the comments around the changed lines in every modified file, which you can only see by reading the full file.
This dimension is applicable whenever the diff adds a comment OR modifies code that has comments near it; set applicable=false only for diffs with neither, naReason "no comment-relevant changes".`,
  },
  {
    key: "moderation",
    label: "Moderation & Guidelines",
    model: "sonnet",
    lensFile: "review-moderation.md",
    pluginOnly: true,
    scoring:
`Score by what the FEATURE does for the player, which you must have read the code to establish, and by which guideline item you can name.
A — a Part A prohibited item the feature does on a reachable path in a plugin meant for submission, or the export of other players' information from any plugin; name the guideline item.
B — a Part B extra-review item the change newly triggers that its README/description does not surface; a Part C data-protection gap (data leaving the device that the description does not cover); a Part D construct a moderator could not follow in one reading.
C — a Part A/B item in a dev-only plugin; a borderline reading where the feature arguably stays on the allowed side (say which side and why).
D — the feature only organises information the player already sees, and the finding rests on how it is coded rather than what it does.`,
    focus:
`FOCUS — would Jagex moderation accept this change (criteria: review-moderation.md, which points at docs/guidelines.md and docs/submission.md — read both).
Part A prohibited features, Part B features subject to extra review, Part C data protection and the listing, Part D readability as a moderation requirement.
Parts A and B reach beyond the diff: what a feature does is judged from the whole plugin and its README, so read them.`,
  },
  {
    key: "grounding",
    label: "API Grounding",
    model: "sonnet",
    lensFile: "review-api-grounding.md",
    pluginOnly: true,
    grounding: true,
    scoring:
`Score by the reference evidence you found: a CONTRADICTED verdict needs a reference location you read.
A — CONTRADICTED on a path the feature runs: the member, field, event, enum value or var does not exist, or the call form (. vs :), arguments or return contradict the signature you quoted.
B — a T? return read as non-nil on an edge-case path; units or ranges mismatched (0-255 vs 0-1 colour, tiles vs fine units, pixels vs relative) with a visible but not breaking effect; an UNVERIFIED use the feature depends on, after searching the index and docs/ (say what you searched).
C — a mismatch on a rarely used path; UNVERIFIED for a member the existing plugins already call the same way.
D — plausible, but you could not locate the reference entry to confirm or refute it.`,
    focus:
`FOCUS — API GROUNDING: check every plugin API use the diff adds or changes against the real API reference (criteria and method: review-api-grounding.md). The ground truth is the API search index (path below), not your memory.
Applicable whenever the diff adds or changes Lua that calls the plugin API; set applicable=false (naReason "no API use changed") for diffs that touch none.`,
  },
]

// The grounding lens's ground truth is the public API reference, outside the repo, so its finder
// AND its verifiers get the index's location: a verifier without it refutes or demotes a grounding
// finding on the false grounds that it cannot see the reference.
function apiIndexBlock(ctx) {
  const local = ctx && ctx.apiIndexPath
  return [
    local
      ? `API INDEX: a local copy of ${API_INDEX_URL} is at ${local}. Query it with jq (see the lens file for the shape).`
      : `API INDEX: the gather step could not fetch ${API_INDEX_URL}. Fetch it yourself to a temp file ` +
        "(`curl -sfL <url> -o \"$(mktemp)\"`) and query that; if the fetch fails too, check docs/ and the rendered pages with WebFetch.",
    "If you are a VERIFIER: refute a grounding finding only when the reference shows the code's use is correct; when you " +
      "cannot reach any reference at all, do NOT refute — give it band D.",
  ].join("\n")
}

// ---- mechanical checklists -------------------------------------------------------
// The checklist states SCOPE (which lines to look at), never a criterion — the bar each item is
// judged against stays in the lens file. It exists because finders skim rather than enumerate.
// The awk program is POSIX ERE only (no \s, \w, or {n}) so gawk and mawk agree, and it runs
// inside single quotes, so it must never contain a ' (the checklist test enforces both).

// What the comment checklist lists: every added comment block of COMMENT_BLOCK_MIN+ lines, plus
// any block carrying a planning or narration label, whatever its length. A block is a run of
// added `--` lines, or the body of a `--[[ ... ]]` long comment. Shorter blocks are still the
// finder's to review; the checklist is the floor.
const COMMENT_BLOCK_MIN = 5
const COMMENT_HIT_RE = String.raw`[Tt]ask [0-9]+[a-z]?([^A-Za-z0-9]|$)|PLAN STEP|[Pp]lan [Ss]tep|[Pp]hase [0-9]|\(T[0-9][0-9]?\)|(from|per) (the )?review|before this (fix|change)|commit [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]|used to |[Pp]reviously|[Rr]everted|the (old|new) (approach|way|version|implementation)`
const COMMENT_AWK =
  `function flush() { if (bs && (last - bs + 1 >= ${COMMENT_BLOCK_MIN} || hit)) print f ":" bs "-" last " (" (last - bs + 1) " lines" (hit ? ", label/narration hit" : "") "): " first; bs = 0; hit = 0 } ` +
  String.raw`/^\+\+\+ /{flush(); f=substr($0,5); inblk=0; next} /^@@ /{flush(); split($3,a,/[+,]/); n=a[2]; next} ` +
  String.raw`/^\+/{t=substr($0,2); if (inblk || t ~ /^[ \t]*--/) { if (!bs) { bs=n; first=t; sub(/^[ \t]+/, "", first); first=substr(first,1,120) } last=n; ` +
  `if (t ~ /${COMMENT_HIT_RE}/) hit=1; ` +
  String.raw`if (inblk) { if (t ~ /\]=*\]/) inblk=0 } else if (t ~ /^[ \t]*--\[=*\[/ && t !~ /\]=*\]/) inblk=1 } else flush(); n++} END{flush()}`
const COMMENT_PATHSPECS = "'*.lua'"

// Big diffs get several comments finders, one per contiguous run of files, because one finder's
// reading budget does not grow with the diff. Weight = files + checklist items.
const COMMENT_BATCH_TRIGGER = 80
const COMMENT_BATCH_WEIGHT = 60
const COMMENT_MAX_BATCHES = 8

function diffCmd(ctx, pathspecs) {
  return `${G} diff --no-color --no-ext-diff --no-prefix -U0 ${ctx.mergeBase} HEAD -- ${pathspecs}`
}

const shellQuotePaths = (files) => files.filter((f) => !f.includes("'")).map((f) => `'${f}'`).join(" ")

// PURE: the naReason to skip a lens without running its finder, or null to run it. The rs-api,
// moderation and grounding lenses judge plugin code only, so a diff that touches nothing under
// plugins/ (a script, the docs, the review tooling itself) would pay their full prompt for an
// applicable=false.
function lensPrecheck(dim, files) {
  if (dim.pluginOnly && Array.isArray(files) && !files.some((f) => /^plugins\//.test(f))) {
    return "precheck: no plugin changes in the diff"
  }
  return null
}

// PURE: "path:N" strings -> { path: N }. Split on the LAST colon; a malformed entry is ignored.
function parseCounts(lines) {
  const out = {}
  for (const l of lines || []) {
    const s = String(l || "").trim()
    const i = s.lastIndexOf(":")
    const n = parseInt(s.slice(i + 1), 10)
    if (i > 0 && Number.isFinite(n) && n > 0) out[s.slice(0, i)] = (out[s.slice(0, i)] || 0) + n
  }
  return out
}

// PURE: split the changed .lua files into comments-finder batches. One batch (every file) unless
// the total weight passes the trigger; then contiguous runs of the sorted paths, so a plugin stays
// together, each at most `cap` weight — a single file heavier than the cap gets a batch of its own
// rather than being split. `cap` is the smallest (>= target) whose greedy packing fits in
// maxBatches; total/maxBatches alone does not, since whole files pack unevenly.
function commentBatches(files, counts, trigger, target, maxBatches) {
  const sorted = [...new Set(files || [])].filter((f) => /\.lua$/.test(f)).sort()
  const weight = (f) => 1 + (counts[f] || 0)
  const total = sorted.reduce((s, f) => s + weight(f), 0)
  if (total <= trigger) return [sorted]
  const pack = (cap) => {
    const batches = []
    let cur = []
    let w = 0
    for (const f of sorted) {
      if (cur.length && w + weight(f) > cap) {
        batches.push(cur)
        cur = []
        w = 0
      }
      cur.push(f)
      w += weight(f)
    }
    if (cur.length) batches.push(cur)
    return batches
  }
  // Greedy batch count only falls as cap rises, and cap = total always gives one batch.
  let lo = Math.max(target, Math.ceil(total / maxBatches))
  let hi = Math.max(lo, total)
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2)
    if (pack(mid).length <= maxBatches) hi = mid
    else lo = mid + 1
  }
  return pack(lo)
}

function commentChecklistBlock(dim, ctx) {
  const counts = parseCounts(ctx.commentBlockCounts)
  const scope = dim.batch ? dim.batch.files : null
  const expected = Object.entries(counts)
    .filter(([f]) => !scope || scope.includes(f))
    .reduce((s, [, n]) => s + n, 0)
  const lines = []
  if (dim.batch) {
    lines.push(
      `BATCH ${dim.batch.index} of ${dim.batch.total} — this diff is too large for one comments reviewer, so it is ` +
        `split by file. Your scope is ONLY these ${scope.length} file(s); other reviewers cover the rest:`,
      ...scope.map((f) => `  ${f}`),
    )
  }
  if (expected) {
    lines.push(
      `COMMENT CHECKLIST — in your scope the diff adds ${expected} comment block(s) that are ${COMMENT_BLOCK_MIN}+ lines ` +
        "long or carry a planning/narration label. List them with exactly this command:",
      `  ${diffCmd(ctx, scope ? shellQuotePaths(scope) : COMMENT_PATHSPECS)} | awk '${COMMENT_AWK}'`,
      "Judge EVERY printed block against Part A of your lens, one by one, and return one commentChecklist entry per " +
        "block — item = the `path:start-end` it printed, verdict \"finding\" when you raised a finding for it, " +
        "\"passes\" with a one-line why otherwise. For a block of 8+ lines the why of a pass must state the halving " +
        "test's result. The list is the floor, not the scope: shorter comments, and Parts B and C, are still yours. " +
        "An item left unresolved is a miss.",
    )
  }
  return lines.join("\n")
}

// PURE: "path:line" of a checklist item or entry, whitespace-normalised; null when absent.
const normItem = (s) => String(s || "").replace(/\s+/g, " ").trim()
function itemLoc(s) {
  const m = /^(\S+?:\d+)/.exec(normItem(s))
  return m ? m[1] : null
}

// PURE: files whose comment checklist the finder did not finish, as "path (k of N unresolved)".
// The finder regenerates the items itself (see commentBlockCounts), so each file must come back
// with at least as many DISTINCT `path:start` entries as gather counted.
function unresolvedCommentCounts(counts, scope, returned) {
  const seen = {}
  for (const r of returned || []) {
    const l = itemLoc(r && r.item)
    if (!l) continue
    const f = l.slice(0, l.lastIndexOf(":"))
    ;(seen[f] = seen[f] || new Set()).add(l)
  }
  return Object.entries(counts)
    .filter(([f]) => !scope || scope.includes(f))
    .map(([f, n]) => [f, n, seen[f] ? seen[f].size : 0])
    .filter(([, n, got]) => got < n)
    .map(([f, n, got]) => `${f} (${n - got} of ${n} comment blocks unresolved)`)
}

function focusBlock() {
  if (!FOCUS) return ""
  return (
    `USER FOCUS — the person who requested this review asked: "${FOCUS}". If that touches your lens, treat it as ` +
    "the priority: work that area exhaustively, and set focusReport to what you checked for it, with counts (e.g. " +
    "\"14 API calls checked, 2 findings\"), even when you found nothing. If it does not touch your lens, " +
    "leave focusReport empty."
  )
}

function finderPrompt(dim, ctx) {
  return [
    REPO_NOTE,
    `You are reviewing the commits ${ctx.mergeBaseShort}..${ctx.headShort} on "${ctx.branch}" (base ${ctx.mergeBase}, exclusive).`,
    `Run \`${G} diff ${ctx.mergeBase} HEAD\` to see all changes, and read source files as needed.`,
    `Changed files (${ctx.fileCount}):`,
    ctx.files.join("\n"),
    ctx.plugins && ctx.plugins.length ? `Affected plugins: ${ctx.plugins.join(", ")}` : "",
    "",
    DEPTH_TEXT[effort.depth],
    "",
    lensBlock(dim),
    "",
    dim.grounding ? apiIndexBlock(ctx) : "",
    dim.focus,
    dim.commentChecklist ? commentChecklistBlock(dim, ctx) : "",
    focusBlock(),
    "",
    "Return structured findings only — no prose narrative. For each finding give severity " +
      "(critical|warning|info), file path, line range, the Part it came from (A/B/C/... if applicable), " +
      "a one-line summary, a minimal quoted snippet, and a one-line suggestion that names the consequence — " +
      "what happens in the client, or for a comment or a guideline the consequence for the next reader or the " +
      "moderator. For a comment-conciseness finding the suggestion IS the complete replacement comment, not a " +
      "description of what to cut. " +
      "`line` is the line number in the file as it stands at HEAD — never a line number from a diff or a grep " +
      "of a diff (those cite lines past the end of the file and get refuted). " +
      "A downstream verify pass DEMOTES uncertain findings to a low-confidence appendix " +
      "rather than deleting them, so report a real-but-arguable issue rather than dropping it. " +
      "If your focus does not apply to this diff, set applicable=false and give a short naReason.",
  ].filter(Boolean).join("\n")
}

// Without the lens a verifier scores against general taste alone, so a criterion only the lens
// names (the halving test, the 1000 ms limit, a guideline item) reads as stylistic and lands in
// the appendix.
function verifyLensBlock(dim) {
  if (!dim.lensFile) return ""
  return [
    "LENS — the finding was raised under these criteria. Read them (at least the Part it cites) before scoring:",
    ...lensReadCommands(dim),
  ].join("\n")
}

// RECALL-FIRST verify contract: `refuted` means FACTUALLY WRONG, not merely minor. A
// real-but-arguable or low-impact finding is NOT refuted — it is kept and given a lower band
// (which routes it to the low-confidence appendix downstream).
const REFUTE_ONLY_IF =
  "Set refuted=true ONLY when the finding is FACTUALLY WRONG — i.e. one of:\n" +
  "  - the code it describes does not exist, or the finding misreads what the code actually does;\n" +
  "  - the concern is already handled elsewhere (a guard, a pcall, a nil check the finding overlooked);\n" +
  "  - it is purely something scripts/check.sh rejects (Lua syntax, plugin.json JSON, stylua formatting, what " +
  "selene flags: unused variables, accidental globals; or what LuaLS flags against the docs/api/ stubs: an undefined " +
  "global) — assume the gate ran and passed. LuaLS only checks API members, call forms (. vs :), argument order and " +
  "nil flow where the value is typed, and trusts the stubs, so never refute those on this ground;\n" +
  "  - it targets code this change did NOT touch AND the change introduces no new consequence on that code (truly pre-existing and unrelated);\n" +
  "  - it is explicitly justified in code or sanctioned by CLAUDE.md — unless the lens file says that kind of " +
  "justification does not excuse it.\n" +
  "Do NOT refute a finding merely because it is minor, stylistic, arguable, or you are unsure it matters in practice — " +
  "those stay (refuted=false) in whatever band their lens gives them. Only kill what is demonstrably incorrect. " +
  "When the finding turns on what the plugin API does, check docs/ or the API reference rather than judging from memory."

// The band letters are shared so `effort.primaryBand` means the same thing for every lens; what a
// finding must have shown to earn each band comes from the lens's own `scoring`. There is
// deliberately no generic "minor" band here: one would let verifiers discount findings that met a
// lens's band B clause word for word.
function rubricBlock(dim) {
  return [
    "Then give each finding you did NOT refute exactly ONE band, A, B, C or D. The band only decides whether the " +
      "finding lands in the main report (A, B) or a low-confidence appendix (C, D).",
    dim.scoring ? `\nBANDS FOR THE ${dim.label.toUpperCase()} LENS:\n${dim.scoring}\n` : "",
    "How to band:",
    "  - Find the band whose clause the finding MEETS on the evidence you read, and quote that clause (a few words) in `matched`. " +
      "If it meets clauses in two bands, take the higher one.",
    "  - The band text already prices in impact and likelihood. Once a finding meets a band's clause, give it that band: do NOT " +
      "step down for \"minor\", \"small\", \"rare\", \"dev-only\", \"drift risk\" or \"arguable\" unless the band text itself names " +
      "that condition.",
    "  - A verified breach of a rule CLAUDE.md or the lens file names explicitly is at least B unless a band clause places it " +
      "lower — the rule is written down, so it is not a style preference.",
    "  - If you genuinely cannot tell whether a finding is real after reading the code, do NOT refute it — give it D and let " +
      "the appendix surface it.",
  ].filter(Boolean).join("\n")
}

function findingBlock(f, key, dim) {
  return [
    `[${key}] (dimension: ${dim.label}, severity: ${f.severity}${f.part ? `, part: ${f.part}` : ""})`,
    `  file: ${f.file}${f.line ? ":" + f.line : ""}`,
    `  summary: ${f.summary}`,
    f.snippet ? `  snippet: ${f.snippet}` : "",
    f.suggestion ? `  suggestion: ${f.suggestion}` : "",
  ].filter(Boolean).join("\n")
}

// Every vote on a group gets this exact prompt: an agent whose first message matches an earlier
// one reads its prefix from the prompt cache instead of writing it again, and a vote number in
// the text would stop that.
function verifyGroupPrompt(group, keys, dim, ctx) {
  const n = group.length
  return [
    REPO_NOTE,
    `You are a verifier for ${n === 1 ? "a code-review finding" : `a group of ${n} code-review findings`} ` +
      `raised by the ${dim.label} lens. Read the real code and decide, for EACH finding, whether it is FACTUALLY WRONG ` +
      "(refute it) or REAL (keep it, banded against its lens). You are NOT trying to kill findings — you are trying to be accurate.",
    n > 1
      ? "The findings are grouped because they sit in the same or neighbouring folders, so the code you read for one " +
        "usually serves the others — read it once. Judge each on its own evidence: one being wrong says nothing about " +
        "another, even on the same line, and never merge two into one verdict."
      : "",
    `Commits ${ctx.mergeBaseShort}..${ctx.headShort} (base ${ctx.mergeBase}). Use \`${G} diff ${ctx.mergeBase} HEAD\` and read the actual source — including the callers and events of any changed code — do not trust a finding's description.`,
    "",
    "FINDINGS:",
    ...group.map((f, i) => findingBlock(f, keys[i], dim)),
    "",
    dim.grounding ? apiIndexBlock(ctx) : "",
    verifyLensBlock(dim),
    REFUTE_ONLY_IF,
    "",
    rubricBlock(dim),
    "",
    "Output ONLY a JSON object as your final message (optionally inside a ```json fence), shaped EXACTLY " +
      `{ "verdicts": [ { "key": "${keys[0]}", "refuted": <boolean>, "band": "A"|"B"|"C"|"D", "matched": "<band clause>", "reasoning": "<one line>" }, ... ] } — ` +
      `one entry per finding, ALL ${n} keys (${keys.join(", ")}): key (string), refuted (boolean — true only if ` +
      "factually wrong), band (one letter; any value for a refuted finding), matched (string, the band clause the " +
      "finding meets), reasoning (string, one line). A key you leave out counts as no " +
      "verdict for that finding. Return the object directly — do NOT stringify it and do NOT nest it under another key.",
  ].filter(Boolean).join("\n")
}

// ---- grouped verify
// PURE: one lens's findings -> verifier groups of at most `cap`, as arrays of the same finding
// objects. Findings are bucketed by folder and the folders packed whole in path order, so a
// folder's findings share a verifier and its sibling folders fill the rest of the group. Only a
// folder with more than `cap` findings is split, into near-equal runs in file+line order so one
// file's findings stay adjacent.
function verifyGroups(findings, cap) {
  const dirOf = (f) => {
    const s = String((f && f.file) || "")
    const i = s.lastIndexOf("/")
    return i > 0 ? s.slice(0, i) : ""
  }
  const byFileLine = (a, b) =>
    String(a.file || "").localeCompare(String(b.file || "")) || (parseInt(a.line, 10) || 0) - (parseInt(b.line, 10) || 0)
  const folders = new Map()
  for (const f of [...(findings || [])].filter(Boolean).sort(byFileLine)) {
    const d = dirOf(f)
    if (!folders.has(d)) folders.set(d, [])
    folders.get(d).push(f)
  }
  const units = []
  for (const d of [...folders.keys()].sort()) {
    const items = folders.get(d)
    const parts = Math.ceil(items.length / cap)
    for (let p = 0; p < parts; p++) {
      units.push(items.slice(Math.round((p * items.length) / parts), Math.round(((p + 1) * items.length) / parts)))
    }
  }
  const groups = []
  let cur = []
  for (const u of units) {
    if (cur.length && cur.length + u.length > cap) {
      groups.push(cur)
      cur = []
    }
    cur = cur.concat(u)
  }
  if (cur.length) groups.push(cur)
  return groups
}

// PURE: one finding's verdicts (a null per dead vote) -> the scored finding, or null if refuted.
function scoreFinding(f, dim, verdicts, primaryBand) {
  const v = verdicts.filter(Boolean)
  // RECALL-FIRST survival: drop a finding ONLY if a MAJORITY of verifiers mark it refuted
  // (factually wrong). Everything else is KEPT — never silently deleted for being low-confidence.
  if (v.length === 0) {
    // No verdict (verifiers died, or skipped this key). Keep it as appendix rather than losing
    // a finding to infrastructure failure.
    return { ...f, dimension: dim.key, label: dim.label, confidence: 0, votes: 0, tier: "appendix" }
  }
  // The majority is over the votes REQUESTED, not the ones that arrived: a verifier that died or
  // skipped this key must not let a lone refuter delete the finding. With too few votes to drop
  // it, a refuted-only finding falls through to confidence 0 -> appendix.
  const refutedVotes = v.filter((x) => x.refuted).length
  if (refutedVotes > verdicts.length / 2) return null
  const kept = v.filter((x) => !x.refuted)
  const bar = BAND_SCORE[primaryBand] ?? BAND_SCORE.B
  const scoreOf = (x) => (x.refuted ? 0 : BAND_SCORE[x.band] ?? x.confidence ?? 0)
  // Confidence averages the NON-refuting verdicts (a lone refuter in a 2-vote split shouldn't
  // drag a real finding's score to zero); it orders and labels findings but does not tier them.
  const base = kept.length ? kept : v
  const avg = Math.round(base.reduce((s, x) => s + scoreOf(x), 0) / base.length)
  // Tier by vote, not by the average: a finding goes to the main report when at least half its
  // non-refuting verifiers banded it at or above primaryBand. Averaging a B with a C lands under
  // the bar, so a single dissent would demote every split finding; recall-first, a tie promotes.
  const clearing = kept.filter((x) => scoreOf(x) >= bar).length
  const tier = kept.length && clearing * 2 >= kept.length ? "primary" : "appendix"
  const bands = v.map((x) => (x.refuted ? "refuted" : x.band)).filter(Boolean)
  return { ...f, dimension: dim.key, label: dim.label, confidence: avg, bands, votes: v.length, tier }
}

// One stand-in per class of vote that scoreFinding tells apart: dead, refuted, kept at or above
// any primaryBand, kept below it.
const VOTE_CLASSES = [
  null,
  { refuted: true, band: "D", confidence: 0 },
  { refuted: false, band: "A", confidence: BAND_SCORE.A },
  { refuted: false, band: "D", confidence: BAND_SCORE.D },
]

// PURE: true when the votes still to come cannot change whether a finding is dropped or which
// tier it lands in, so they need not be run. At medium (2 votes), a first vote that keeps a
// finding at or above the bar already makes it primary: a second can neither drop it (that takes
// both refuting) nor demote it (a tie promotes).
function voteDecided(f, dim, got, requested, primaryBand) {
  const outcome = (verdicts) => {
    const s = scoreFinding(f, dim, verdicts, primaryBand)
    return s ? s.tier : "dropped"
  }
  let completions = [got]
  for (let i = got.length; i < requested; i++) {
    completions = completions.flatMap((c) => VOTE_CLASSES.map((x) => c.concat([x])))
  }
  const first = outcome(completions[0])
  return completions.every((c) => outcome(c) === first)
}

// A re-run of a group's own prompt reads its prefix from cache; a repacked group is a new prompt
// that writes it again. Measured in kawaka: ~59k vs ~94k input-token-equivalents per verifier.
const CACHED_RERUN_COST = 0.63

// PURE: the next vote round for one lens. `groups` are the round-1 groups (arrays of finding
// indexes); `open` is the set of indexes still undecided. Either re-run every group that holds an
// open finding with its unchanged prompt (its decided findings get a vote they did not need), or
// repack only the open findings into new groups, whichever costs less.
function nextVoteRound(groups, open, findings, cap) {
  const rerun = groups.filter((g) => g.some((i) => open.has(i)))
  const byFinding = new Map(findings.map((f, i) => [f, i]))
  const repacked = verifyGroups([...open].sort((a, b) => a - b).map((i) => findings[i]), cap)
    .map((g) => g.map((f) => byFinding.get(f)))
  return rerun.length * CACHED_RERUN_COST <= repacked.length
    ? { mode: "rerun", groups: rerun }
    : { mode: "repack", groups: repacked }
}
// ---- end grouped verify

// ---- run -------------------------------------------------------------------
phase("Gather")
const ctx = await agent(
  REPO_NOTE +
    "Gather code-review context for a range of commits.\n" +
    "Run:\n" +
    `  ROOT=$(${G} rev-parse --show-toplevel)   # repoRoot (ABSOLUTE path of the repo being reviewed)\n` +
    `  MB="${BASE_ARG}"\n` +
    "  # No base given: use the run's recorded base from durable state.\n" +
    "  [ -n \"$MB\" ] || MB=$(jq -r '.base // empty' \"$ROOT/.durable-state/state.json\" 2>/dev/null)\n" +
    `  MB=$(${G} rev-parse --verify --quiet "$MB^{commit}")   # mergeBase (full sha); empty -> not eligible\n` +
    `  ${G} rev-parse --short "$MB"       # mergeBaseShort\n` +
    `  ${G} rev-parse --short HEAD        # headShort\n` +
    `  ${G} rev-parse --abbrev-ref HEAD   # branch\n` +
    `  ${G} diff --name-only "$MB" HEAD   # files\n` +
    `  ${G} diff --name-only "$MB" HEAD | grep -oE '^plugins/[^/]+' | sort -u   # plugins\n` +
    "  # commentBlockCounts: per file, how many added comment blocks the comments checklist will list, as path:N\n" +
    `  ${G} diff --no-color --no-ext-diff --no-prefix -U0 "$MB" HEAD -- ${COMMENT_PATHSPECS} | awk '${COMMENT_AWK}' | awk -F: '{c[$1]++} END{for (k in c) print k ":" c[k]}'\n` +
    "  # apiIndexPath: a local copy of the API search index for the grounding lens, refreshed daily (dumps/ is gitignored)\n" +
    "  API=\"$ROOT/dumps/api-cache/search.json\"; mkdir -p \"$(dirname \"$API\")\" \"$ROOT/.durable-state/reviews\"\n" +
    `  if [ ! -s "$API" ] || [ -n "$(find "$API" -mmin +1440)" ]; then curl -sfL --max-time 60 ${API_INDEX_URL} -o "$API.tmp" && mv "$API.tmp" "$API"; fi\n` +
    "  [ -s \"$API\" ] && jq -e '.items | length > 0' \"$API\" >/dev/null && echo \"apiIndexPath=$API\"\n" +
    "Set eligible=false (with skipReason) if the base did not resolve to a commit (skipReason \"no base: pass args.base " +
    "or record base in .durable-state/state.json\"), if there are zero changed files, or if the diff is an " +
    "automated/trivial change not worth reviewing. Otherwise eligible=true. Report fileCount as the number of changed " +
    "files. Report commentBlockCounts as every path:N line its command printed, verbatim ([] if it printed nothing). " +
    "Report apiIndexPath as the path the last command printed (empty string \"\" if it printed nothing). " +
    "Return the structured object — do not review anything.",
  { label: "gather", phase: "Gather", model: "haiku", schema: GATHER_SCHEMA }
)

if (!ctx.eligible || ctx.fileCount === 0) {
  log(`Skipping review: ${ctx.skipReason || "no changes in the range"}`)
  return { skipped: true, reason: ctx.skipReason || "no changes in the range", branch: ctx.branch }
}

if (ctx.fileCount > 100) {
  log(`Large diff (${ctx.fileCount} files) — review quality may degrade; consider reviewing one plugin at a time.`)
}
log(`Reviewing ${ctx.fileCount} files, ${ctx.mergeBaseShort}..${ctx.headShort} on "${ctx.branch}", at effort=${effortName} (votes=${effort.votes}, primary-band=${effort.primaryBand}+, depth=${effort.depth}, verify=${effort.verifyModel})`)
if (FOCUS) log(`User focus handed to every finder: "${FOCUS}"`)
log(ctx.apiIndexPath
  ? `API index for the grounding lens: ${ctx.apiIndexPath}`
  : `API index fetch failed — the grounding finder will fetch ${API_INDEX_URL} itself.`)

const commentCounts = parseCounts(ctx.commentBlockCounts)
const commentItemTotal = Object.values(commentCounts).reduce((s, n) => s + n, 0)
const batches = commentBatches(ctx.files, commentCounts, COMMENT_BATCH_TRIGGER, COMMENT_BATCH_WEIGHT, COMMENT_MAX_BATCHES)
// The comments dimension fans out into one finder per batch on a big diff. Every batch keeps
// key "comments", so findings, verify labels and the report group exactly as one finder's would.
const RUN_DIMS = DIMENSIONS.flatMap((dim) => {
  if (!dim.commentChecklist || batches.length <= 1) return [dim]
  return batches.map((files, i) => ({
    ...dim,
    label: `${dim.label} (batch ${i + 1}/${batches.length})`,
    batch: { index: i + 1, total: batches.length, files },
  }))
})
log(`Comment checklist: ${commentItemTotal} added comment block(s) across ${Object.keys(commentCounts).length} file(s)` +
  (batches.length > 1 ? ` — comments lens split into ${batches.length} batches` : ""))

// Checklist items a finder's return left unresolved.
function checklistGaps(dim, r) {
  if (!r || !dim.commentChecklist) return []
  return unresolvedCommentCounts(commentCounts, dim.batch ? dim.batch.files : null, r.commentChecklist)
}

// Pipeline: each dimension reviews, then its findings are verified immediately — dimension 1's
// findings score while the last dimension is still reviewing.
// FAIL-CLOSED COVERAGE: a dead finder would otherwise be indistinguishable from a legitimately
// not-applicable lens, so rate-limit waves would silently shrink the review. A dead finder gets
// ONE retry (fresh label = fresh cache key), and if it still fails the lens is recorded as FAILED
// — the run returns `incomplete: true` and the conductor must not treat it as a full review.
const perDim = await pipeline(
  RUN_DIMS,
  (dim) => {
    const reviewLabel = `review:${dim.key}${dim.batch ? `:b${dim.batch.index}` : ""}`
    const opts = {
      label: reviewLabel,
      phase: "Review",
      model: dim.model,
      // Bound per-turn reasoning so a finder's silent think time can't exceed the harness's
      // no-progress watchdog. Reading DEPTH is a separate knob, so this doesn't shallow the review.
      effort: "medium",
      schema: FINDINGS_SCHEMA,
    }
    const skip = lensPrecheck(dim, ctx.files)
    if (skip) {
      log(`${dim.label}: skipped without a finder — ${skip}`)
      return Promise.resolve({ applicable: false, naReason: skip, findings: [] })
    }
    return agent(finderPrompt(dim, ctx), opts).then((r) => {
      if (!r) return agent(finderPrompt(dim, ctx), { ...opts, label: `${reviewLabel}:retry` })
      // An incomplete checklist gets ONE retry too (fresh label = fresh cache key); a resume
      // would otherwise cache-hit the same incomplete answer forever.
      if (!checklistGaps(dim, r).length) return r
      log(`${dim.label}: ${checklistGaps(dim, r).length} checklist item(s) unresolved — retrying the finder once`)
      return agent(finderPrompt(dim, ctx), { ...opts, label: `${reviewLabel}:checklist-retry` }).then((r2) => r2 || r)
    })
  },
  (review, dim) => {
    if (!review) {
      // Finder died twice — FAILED lens, not "not applicable". Surfaced in coverage.failed.
      return { dimension: dim.key, label: dim.label, applicable: true, failed: true, survivors: [] }
    }
    // FAIL CLOSED on the checklist: an item the finder never resolved means the lens did not
    // finish its job, so it counts as FAILED (coverage.failed -> incomplete: true) while keeping
    // whatever findings it did verify.
    const missing = checklistGaps(dim, review)
    const extras = {
      focusReport: (review.focusReport || "").trim(),
      unreachedFiles: review.unreachedFiles || [],
    }
    const withChecklist = (res) => {
      const out = { ...res, ...extras }
      return missing.length ? { ...out, applicable: true, failed: true, checklistMissing: missing } : out
    }
    if (missing.length) {
      log(`⚠ ${dim.label}: ${missing.length} checklist item(s) never resolved — lens marked FAILED: ${missing.join(" | ")}`)
    }
    if (extras.unreachedFiles.length) {
      log(`${dim.label}: finder reports ${extras.unreachedFiles.length} in-scope file(s) not reached`)
    }
    if (!review.applicable || !review.findings || review.findings.length === 0) {
      return withChecklist({ dimension: dim.key, label: dim.label, applicable: !!review.applicable, naReason: review.naReason, survivors: [] })
    }
    // Votes run in rounds: each round gives every open finding one more verdict, and a finding
    // leaves once the votes still to come could not change its outcome (voteDecided).
    const findings = review.findings
    const batchTag = dim.batch ? `:b${dim.batch.index}` : ""
    const firstGroups = verifyGroups(findings, VERIFY_GROUP_MAX).map((g) => g.map((f) => findings.indexOf(f)))
    const got = findings.map(() => [])
    log(`${dim.label}: ${findings.length} finding(s) -> ${firstGroups.length} verify group(s), up to ${effort.votes} vote(s)`)
    const runGroup = (idxs, label) => {
      const group = idxs.map((i) => findings[i])
      const keys = group.map((_, k) => `F${k + 1}`)
      // Called inside a then(), so a synchronous throw from agent() rejects the chain and reaches
      // the .catch() below instead of escaping runGroup.
      const run = (l, agentType) =>
        Promise.resolve()
          .then(() => agent(verifyGroupPrompt(group, keys, dim, ctx), {
            label: l,
            phase: "Verify",
            model: effort.verifyModel,
            effort: "medium",
            ...(agentType ? { agentType } : {}),
          }))
          .then((raw) => parseVerdicts(raw, keys))
      // A dead or unparseable group vote costs up to VERIFY_GROUP_MAX findings a vote, so it gets
      // ONE retry (fresh label = fresh cache key). The retry runs as the default agent: agent()
      // THROWS on an agent type the session's registry lacks (a session that started before
      // VERIFIER_AGENT existed), and losing that vote would demote every finding in the group.
      return run(label, VERIFIER_AGENT)
        .catch(() => ({}))
        .then((ans) => (Object.values(ans).some(Boolean) ? ans : run(`${label}:retry`, null).catch(() => ({}))))
        .then((ans) => idxs.forEach((i, k) => got[i].push(ans ? ans[keys[k]] : null)))
    }
    const round = (r, plan) =>
      parallel(plan.groups.map((idxs, gi) => () => runGroup(idxs, `verify:${dim.key}${batchTag}:r${r}${plan.mode === "repack" ? "p" : ""}:g${gi + 1}`)))
        .then(() => {
          // A finding a re-run group re-voted after it was decided keeps that extra verdict, but
          // never more than the votes requested.
          got.forEach((v) => v.splice(effort.votes))
          const open = new Set(findings.map((_, i) => i).filter((i) =>
            got[i].length < effort.votes && !voteDecided(findings[i], dim, got[i], effort.votes, effort.primaryBand)))
          if (r >= effort.votes || open.size === 0) return
          const next = nextVoteRound(firstGroups, open, findings, VERIFY_GROUP_MAX)
          log(`${dim.label}: vote round ${r + 1}: ${open.size} finding(s) still open -> ${next.groups.length} group(s) (${next.mode})`)
          return round(r + 1, next)
        })
    return round(1, { mode: "rerun", groups: firstGroups }).then(() =>
      withChecklist({
        dimension: dim.key,
        label: dim.label,
        applicable: true,
        // Pad with dead votes up to the number requested, so scoreFinding's majority is over the
        // votes asked for, exactly as when every vote ran.
        survivors: findings
          .map((f, i) => scoreFinding(f, dim, got[i].concat(Array(effort.votes - got[i].length).fill(null)), effort.primaryBand))
          .filter(Boolean),
      })
    )
  }
)

// A stage that threw drops its item to null — treat that exactly like a dead finder so no lens
// ever silently vanishes from the coverage accounting.
const dims = RUN_DIMS.map(
  (dim, i) => perDim[i] || { dimension: dim.key, label: dim.label, applicable: true, failed: true, survivors: [] }
)
const failedLenses = dims.filter((d) => d.failed).map((d) => d.label)
const coverage = {
  // applicable = every lens that should have produced findings (self-skipped lenses excluded;
  // a FAILED lens counts as applicable — its applicability is unknown, so assume the worst).
  applicable: dims.filter((d) => d.applicable).map((d) => d.label),
  ran: dims.filter((d) => d.applicable && !d.failed).map((d) => d.label),
  failed: failedLenses,
  // Comment-checklist items a finder never resolved — why that lens is in `failed`.
  checklistMissing: dims.flatMap((d) => d.checklistMissing || []),
  // In-scope files a finder said it did not reach.
  unreached: dims.flatMap((d) => (d.unreachedFiles || []).map((f) => `${d.label}: ${f}`)),
}
const focusReports = dims.filter((d) => d.focusReport).map((d) => `${d.label}: ${d.focusReport}`)
if (failedLenses.length) {
  log(`⚠ INCOMPLETE REVIEW: ${failedLenses.length} lens(es) failed after retry — ${failedLenses.join(", ")}. ` +
    "Findings below are PARTIAL; the conductor must not treat this run as a complete review.")
}
const survivors = dims.flatMap((d) => d.survivors)
const primaries = survivors.filter((f) => f.tier === "primary")
const primaryCount = primaries.length
const appendixCount = survivors.filter((f) => f.tier === "appendix").length
// Severity counts over PRIMARY (actionable) findings only — used for the log + return.
const primaryCritical = primaries.filter((f) => f.severity === "critical").length
const primaryWarning = primaries.filter((f) => f.severity === "warning").length
const primaryInfo = primaries.filter((f) => f.severity === "info").length
const naList = dims.filter((d) => !d.applicable).map((d) => `${d.label}${d.naReason ? " (" + d.naReason + ")" : ""}`)
// "Clean" = the dimension kept NOTHING (no primary and no appendix). A dimension that produced
// only appendix findings is NOT clean — its findings still show in the low-confidence section.
const cleanList = dims.filter((d) => d.applicable && d.survivors.length === 0).map((d) => d.label)
log(`${survivors.length} findings kept (${primaryCount} primary, ${appendixCount} low-confidence appendix) across ${dims.length} dimensions`)

// Assign STABLE finding ids (C1.., W1.., I1..) BEFORE synthesis, so the conductor and the human
// can address a finding by id across the report, the fix loop and the final summary. Sort by
// severity, then tier, then file, then line, then summary so the ordering (and thus the ids) is
// deterministic even when several findings share a severity+file.
const SEV_ORDER = { critical: 0, warning: 1, info: 2 }
const SEV_PREFIX = { critical: "C", warning: "W", info: "I" }
const TIER_ORDER = { primary: 0, appendix: 1 }
const counters = { critical: 0, warning: 0, info: 0 }
const findingsList = [...survivors]
  .sort((a, b) => {
    const bySev = (SEV_ORDER[a.severity] ?? 3) - (SEV_ORDER[b.severity] ?? 3)
    if (bySev !== 0) return bySev
    // Primary before appendix within a severity, so main-report findings claim the low ids
    // (W1..Wn contiguous) and demoted ones continue the sequence.
    const byTier = (TIER_ORDER[a.tier] ?? 0) - (TIER_ORDER[b.tier] ?? 0)
    if (byTier !== 0) return byTier
    const byFile = String(a.file || "").localeCompare(String(b.file || ""))
    if (byFile !== 0) return byFile
    const byLine = (parseInt(a.line, 10) || 0) - (parseInt(b.line, 10) || 0)
    if (byLine !== 0) return byLine
    return String(a.summary || "").localeCompare(String(b.summary || ""))
  })
  .map((f) => {
    counters[f.severity] = (counters[f.severity] || 0) + 1
    // Spread f first, set id last — the computed stable id is authoritative and must never be
    // clobbered by a stray `id` field on the raw finding.
    return { ...f, id: `${SEV_PREFIX[f.severity] || "X"}${counters[f.severity]}` }
  })

// ---- candidate duplicate clusters -------------------------------------------------
// Two lenses looking at the same code from different angles routinely raise the SAME issue twice
// (a nil index is both a correctness and an API-grounding finding), and asking the synthesis
// agent to notice does not work: findingsList is sorted by severity FIRST, so a warning and an
// info about one line sit far apart in its context.
//
// So compute the candidates here rather than hoping. This is a PROPOSAL, not a merge: nothing is
// dropped, no id changes, and the agent still decides same-issue or not. Because a false
// candidate only costs the agent one "these are distinct" sentence, the proximity window is
// deliberately generous — a missed duplicate is the expensive direction.
//
// Cross-dimension only. Two findings from ONE lens on nearby lines are usually genuinely distinct
// (a lens walking a file finds several things); the failure mode being fixed here is one piece of
// code seen through two different lenses.
const CLUSTER_PROXIMITY_LINES = 30

// `line` is free text from the finder — "16", "449-458", "230, 252, 283, 306, 335".
function parseLineSpec(line) {
  const spans = []
  for (const part of String(line ?? "").split(",")) {
    const m = part.match(/(\d+)\s*(?:[-–—]\s*(\d+))?/)
    if (!m) continue
    const a = parseInt(m[1], 10)
    const b = m[2] ? parseInt(m[2], 10) : a
    if (Number.isFinite(a) && Number.isFinite(b)) spans.push([Math.min(a, b), Math.max(a, b)])
  }
  return spans
}

// True when any span of one finding is within CLUSTER_PROXIMITY_LINES of any span of the
// other (overlap included) — the gap test in both directions.
function spansNearby(as, bs) {
  return as.some(([s1, e1]) =>
    bs.some(([s2, e2]) => s1 <= e2 + CLUSTER_PROXIMITY_LINES && s2 <= e1 + CLUSTER_PROXIMITY_LINES))
}

const dsu = findingsList.map((_, i) => i)
const dsuFind = (i) => (dsu[i] === i ? i : (dsu[i] = dsuFind(dsu[i])))
const allSpans = findingsList.map((f) => parseLineSpec(f.line))
for (let i = 0; i < findingsList.length; i++) {
  for (let j = i + 1; j < findingsList.length; j++) {
    if (findingsList[i].file !== findingsList[j].file) continue
    if (findingsList[i].dimension === findingsList[j].dimension) continue
    if (!allSpans[i].length || !allSpans[j].length) continue
    if (!spansNearby(allSpans[i], allSpans[j])) continue
    const a = dsuFind(i)
    const b = dsuFind(j)
    if (a !== b) dsu[a] = b
  }
}
const clusterMap = new Map()
findingsList.forEach((f, i) => {
  const root = dsuFind(i)
  if (!clusterMap.has(root)) clusterMap.set(root, [])
  clusterMap.get(root).push(f)
})
const dupCandidates = [...clusterMap.values()].filter((c) => c.length > 1)
if (dupCandidates.length) {
  log(`${dupCandidates.length} candidate duplicate cluster(s) for synthesis to adjudicate: ` +
    dupCandidates.map((c) => `[${c.map((f) => f.id).join(", ")}]`).join(" "))
}
// Always emit this block, even when empty. An absent block leaves task 2's "the clusters listed
// above" with no referent, which invites the agent to invent one or narrate about its absence;
// an explicit "none" closes the question.
const dupBlock = dupCandidates.length
  ? [
      "",
      "CANDIDATE DUPLICATE CLUSTERS — computed from file + line proximity across DIFFERENT " +
        "dimensions. These are candidates, NOT a verdict: some are one issue two lenses found, " +
        "others are genuinely distinct problems that happen to sit near each other. You MUST " +
        "adjudicate every cluster (see task 2).",
      ...dupCandidates.map(
        (c) =>
          `  - ${c.map((f) => `${f.id} (${f.dimension}, ${f.file}:${f.line})`).join("  ||  ")}`),
    ].join("\n")
  : "\nCANDIDATE DUPLICATE CLUSTERS — none. No two findings from different lenses landed close " +
    "enough in one file to be worth checking. Task 2 has nothing to adjudicate: do not look for " +
    "duplicates yourself, do not invent clusters, and do not mention their absence in the report."

phase("Report")
// Resolve the report path deterministically in-script so it always lands in the repo BEING
// REVIEWED (ctx.repoRoot from gather honours repoPath), never the synth agent's cwd. It goes
// under the gitignored .durable-state/ so it never lands in a commit.
const reportDir = (ctx.repoRoot && ctx.repoRoot.trim()) || REPO || "."
const reportPath = `${reportDir.replace(/\/+$/, "")}/.durable-state/reviews/review-${ctx.mergeBaseShort}..${ctx.headShort}.md`
const synth = await agent(
  [
    `Write a deduplicated, id-keyed code-review report for commits ${ctx.mergeBaseShort}..${ctx.headShort} on "${ctx.branch}" (${ctx.fileCount} files, effort=${effortName}).`,
    `Affected plugins: ${(ctx.plugins || []).join(", ") || "n/a"}.`,
    `Dimensions that found nothing: ${cleanList.join(", ") || "none"}.`,
    `Dimensions not applicable: ${naList.join(", ") || "none"}.`,
    failedLenses.length
      ? `⚠ FAILED DIMENSIONS (agents died — their territory was NOT reviewed): ${failedLenses.join(", ")}. ` +
        "Open the report with a prominent '## ⚠ INCOMPLETE COVERAGE' banner listing them and stating that this " +
        "report is PARTIAL and must not be treated as a clean review."
      : "",
    FOCUS
      ? `REQUESTED FOCUS: the review was requested with "${FOCUS}". After the header, render a '## Requested Focus' ` +
        "section quoting it, then one bullet per lens report below, verbatim" +
        (focusReports.length ? ":\n" + focusReports.map((r) => `  - ${r}`).join("\n") : " — no lens reported on it; say so plainly.")
      : "",
    coverage.unreached.length
      ? "FILES NOT REACHED — finders reported these in-scope files as unread. List them under a '## Coverage Gaps' " +
        "section just before the Summary:\n" + coverage.unreached.map((u) => `  - ${u}`).join("\n")
      : "",
    `AUTHORITATIVE COUNTS (use these VERBATIM in the Summary — do NOT recount from the JSON): ` +
      `primary = ${primaryCritical} critical, ${primaryWarning} warning, ${primaryInfo} info (${primaryCount} total); ` +
      `appendix = ${appendixCount} low-confidence findings.`,
    "",
    "Verified findings (already confidence-scored and assigned STABLE ids) as JSON. Each has a `tier`: " +
      "\"primary\" (main report, defaults to Fix) or \"appendix\" (low-confidence / worth-a-look, defaults to Skip):",
    JSON.stringify(findingsList, null, 2),
    dupBlock,
    "",
    "A conductor fixes the primary findings from this report and adjudicates each appendix one (fix, reject or defer), both by id, so " +
      "every finding MUST be a self-contained, individually addressable block keyed by its id — never merge two " +
      "distinct issues into one.",
    "",
    "Tasks:",
    "1. Render EVERY finding from the JSON above — do NOT drop any. Keep its given `id` verbatim.",
    "2. ONLY IF the CANDIDATE DUPLICATE CLUSTERS block above lists clusters — if it says none, skip this task " +
      "entirely and write nothing about it. Otherwise adjudicate EVERY cluster it lists; each gets exactly one of " +
      "these two outcomes, and saying nothing is not an option:\n" +
      "   (a) SAME ISSUE — the findings describe one problem with one fix, even where their line anchors or wording " +
      "differ. Render ONE block carrying EVERY id in the heading (`### [I6, I7] <file>:<line> — …`), merge their " +
      "reasoning, and attribute it to all the dimensions that raised it. A reader must decide it once, not twice.\n" +
      "   (b) DISTINCT — they are separate problems that happen to sit near each other. Render them separately and add " +
      "`Distinct from [<other ids>]: <one line on the difference>` to each, so the reader can see the overlap was " +
      "considered rather than missed.\n" +
      "   Judge by whether ONE fix resolves them all, not by whether the line numbers match. Never drop an id either way.",
    "3. If any findings genuinely conflict (one says do X, another do not-X), keep both and add a 'Conflicts:' note on each.",
    "4. Severity (critical|warning|info) and tier (primary|appendix) are ALREADY decided per finding — keep both; " +
      "never re-classify a finding. A block merged under task 2(a) is filed in the section of its STRONGEST member " +
      "(critical > warning > info; primary > appendix) because it can only appear once, while each id inside it keeps " +
      "the severity and tier it arrived with. State every member id with its own severity in the block, e.g. " +
      "`### [W4 (warning), I9 (info)] …`. The AUTHORITATIVE COUNTS above are per FINDING ID, not per rendered block, " +
      "so a merged block makes the section's block count smaller than its count — that is expected; still print the " +
      "counts verbatim and never adjust them to match what you rendered.",
    `5. Write the report (markdown) to EXACTLY this absolute path — it is already resolved, do NOT compute your own: ` +
      `${reportPath}\n` +
      "   Write it with the Write tool, never a shell heredoc or `cat >`. If the write fails, retry once with the Write " +
      "tool; if it still fails, return reportWritten=false rather than pretending it landed.\n" +
      "   Structure: a header (commit range, files changed, plugins, effort, main-report bar: band " +
      `${effort.primaryBand} or higher). Then render, IN THIS ORDER:\n` +
      "   - ## Critical Issues, ## Warnings, ## Info — containing ONLY tier=\"primary\" findings of that severity, ordered by file.\n" +
      "   - ## Low-Confidence — Worth a Look — containing ALL tier=\"appendix\" findings (any severity), ordered by severity then file. " +
      "These are kept-but-uncertain findings the verify pass could not confirm as high-impact; their DEFAULT is Skip.\n" +
      "   - ## High-Confidence Findings — the clusters you judged SAME ISSUE in task 2, i.e. one problem two or more " +
      "lenses independently found (primary only). List each by its merged id set and one line on why the agreement " +
      "matters. Omit the section entirely if task 2 produced no same-issue clusters.\n" +
      "   - ## Summary — render the AUTHORITATIVE COUNTS given above VERBATIM (primary C/W/I + appendix total); do not recount. Then the clean/N-A dimension lists.\n" +
      "   Render EACH finding as (a block merged under task 2(a) carries all its ids here, comma-separated):\n" +
      "      ### [<id>] <file>:<line> — <one-line summary>\n" +
      "      <description / why it matters + the consequence in the client (or for the reader/moderator)>; confidence <score> (bands <bands, joined with />); flagged by <dimension(s)>.\n" +
      "      <minimal snippet and/or concrete suggestion>\n" +
      "      **Resolution:** <Fix for primary findings | Skip for appendix findings>",
    "6. If there are zero findings, still write the report stating no issues were found and listing the clean and " +
      "not-applicable dimensions.",
    `Return reportPath set to exactly ${reportPath}, reportWritten (true only if the Write tool call succeeded), and the ` +
      "critical/warning/info counts (count PRIMARY findings only for these).",
  ].join("\n"),
  { label: "synthesize", phase: "Report", model: "sonnet", effort: "medium", schema: SYNTH_SCHEMA }
)

// Use the in-script reportPath as authoritative (not the synth agent's self-report) so the
// conductor always finds the report in the reviewed tree.
// FAIL CLOSED: any failed lens (or a dead synthesis agent) marks the whole run `incomplete` —
// the conductor MUST check this flag and not treat the run as a full review. The partial findings
// are still returned for triage. Recover by resuming this runId (completed lenses cache-hit; only
// the failed ones re-run) once the failure cause (usually a rate limit) has cleared.
const incomplete = failedLenses.length > 0 || !synth
// A missing report is not a partial REVIEW — findingsList is complete — so it does not set
// `incomplete`; conductors work from findingsList when reportWritten is false.
const reportWritten = !!(synth && synth.reportWritten)
if (!synth) log("⚠ Synthesis agent failed — the report file may not exist; run marked incomplete.")
else if (!reportWritten) log(`⚠ Synthesis agent could not write ${reportPath} — work from findingsList.`)
log(
  `${incomplete ? "⚠ PARTIAL report" : reportWritten ? "Report written" : "⚠ Report NOT written"}: ${reportPath} ` +
    `(${primaryCount} primary: ${primaryCritical}C/${primaryWarning}W/${primaryInfo}I; ${appendixCount} low-confidence appendix)` +
    `${failedLenses.length ? ` — MISSING lenses: ${failedLenses.join(", ")}` : ""}`
)
return {
  branch: ctx.branch,
  base: ctx.mergeBaseShort,
  head: ctx.headShort,
  effort: effortName,
  filesChanged: ctx.fileCount,
  // true when any applicable lens or the synthesis died — findings/counts below are PARTIAL.
  incomplete,
  coverage,
  findings: findingsList.length,
  // primary = main report (default Fix); appendix = low-confidence, kept (default Skip).
  primary: primaryCount,
  appendix: appendixCount,
  // Authoritative severity counts over PRIMARY findings (the actionable set).
  critical: primaryCritical,
  warning: primaryWarning,
  info: primaryInfo,
  reportPath,
  reportWritten,
  // Machine-readable findings (each with a stable id + tier) for the conductor's fix loop.
  findingsList,
}
