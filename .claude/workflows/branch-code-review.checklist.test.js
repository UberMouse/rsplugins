// Test for branch-code-review.js's comment checklist, comment batching and lens precheck.
//
// Run: node .claude/workflows/branch-code-review.checklist.test.js
//
// Like the other workflow tests, this extracts the shipped code between markers and evaluates it,
// so a rename fails loudly. The awk program is run for real against a synthetic `git diff -U0`,
// because its quoting passes through a JS string, a single-quoted shell word and awk's own regex
// syntax — the layer most likely to break silently.

const fs = require("fs")
const path = require("path")
const { execFileSync } = require("child_process")

const SCRIPT = path.join(__dirname, "branch-code-review.js")
const src = fs.readFileSync(SCRIPT, "utf8")

function grab(startMarker, endMarker) {
  const a = src.indexOf(startMarker)
  const b = src.indexOf(endMarker, a)
  if (a < 0 || b < 0) {
    throw new Error(
      `branch-code-review.js no longer contains the marker ${JSON.stringify(startMarker)} ` +
      `followed by ${JSON.stringify(endMarker)} — the checklist block moved or was renamed. ` +
      "Update this test's markers rather than deleting the test.")
  }
  return src.slice(a, b)
}

const block = grab("// ---- mechanical checklists", "function finderPrompt(")
const api = new Function(
  "G", "FOCUS",
  block +
    "; return { COMMENT_AWK, parseCounts, commentBatches, unresolvedCommentCounts, commentChecklistBlock, lensPrecheck };",
)("git", "")

// The whole script must at least parse. It uses top-level await/return, so compile it as the
// body of an async function (never called) after stripping the `export` keyword from meta.
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor
new AsyncFunction("args", "agent", "parallel", "pipeline", "phase", "log", src.replace(/^export const meta/m, "const meta"))

let failures = 0
function check(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a === e) {
    console.log(`ok   ${name}`)
  } else {
    failures++
    console.log(`FAIL ${name}\n     expected ${e}\n     actual   ${a}`)
  }
}

const runAwk = (program, input) =>
  execFileSync("awk", [program], { input, encoding: "utf8" }).split("\n").filter(Boolean)

// ---- COMMENT_AWK ----------------------------------------------------------------

const commentDiff = [
  "+++ plugins/thing/main.lua",
  "@@ -0,0 +1,20 @@",
  "+-- A five-line header block",
  "+-- that explains what the",
  "+-- plugin does, its keys",
  "+-- and that it is not for",
  "+-- submission.",
  "+local RADIUS = 32",
  "+-- Task 3: short but labelled",
  "+local SIZE = RADIUS * 2 + 1",
  "+-- four lines",
  "+-- with no",
  "+-- label in",
  "+-- them at all",
  "+local x = 1 -- a trailing comment is not a block",
  "+--[[",
  "+A long comment whose body",
  "+lines do not start with --",
  "+and still count.",
  "+]]",
  "+++ plugins/thing/util.lua",
  "@@ -10,0 +40,2 @@",
  "+-- this used to recompute every frame",
  "+return M",
  "",
].join("\n")

const commentOut = runAwk(api.COMMENT_AWK, commentDiff)
check("comment awk lists 5+ line blocks and short blocks with a label hit, locations in the new file",
  commentOut.map((l) => l.split(" ")[0]), [
    "plugins/thing/main.lua:1-5",
    "plugins/thing/main.lua:7-7",
    "plugins/thing/main.lua:14-18",
    "plugins/thing/util.lua:40-40",
  ])
check("comment awk does not list a 4-line block with no label hit",
  commentOut.some((l) => l.startsWith("plugins/thing/main.lua:9")), false)
check("comment awk marks label hits", commentOut.filter((l) => l.includes("label/narration hit")).length, 2)
check("comment awk treats a one-line --[[ ]] as a line comment, not an open block",
  runAwk(api.COMMENT_AWK, ["+++ a.lua", "@@ -0,0 +1,2 @@", "+--[[ one line ]] local y = 2", "+local z = 3", ""].join("\n")),
  [])
check("comment awk resets an unclosed long comment at the next file",
  runAwk(api.COMMENT_AWK, [
    "+++ a.lua", "@@ -0,0 +1,1 @@", "+--[[ never closed",
    "+++ b.lua", "@@ -0,0 +1,1 @@", "+local code = true", "",
  ].join("\n")),
  [])

// The finders run this inside a single-quoted shell word, so a ' anywhere in it breaks the
// command. Run the program through sh exactly as the prompts quote it.
check("the awk program contains no single quote", api.COMMENT_AWK.includes("'"), false)
const viaShell = (program, input) =>
  execFileSync("sh", ["-c", `awk '${program}'`], { input, encoding: "utf8" }).split("\n").filter(Boolean)
check("comment awk survives shell quoting", viaShell(api.COMMENT_AWK, commentDiff), commentOut)

// ---- parseCounts / batching -----------------------------------------------------

check("parseCounts splits on the last colon and drops junk",
  api.parseCounts(["a/b.lua:3", "c:d.lua:2", "bad", "x.lua:0"]), { "a/b.lua": 3, "c:d.lua": 2 })
check("one batch of every .lua file below the trigger",
  api.commentBatches(["b.lua", "a.lua", "README.md"], {}, 80, 60, 8), [["a.lua", "b.lua"]])
const bigFiles = Array.from({ length: 30 }, (_, i) => `plugins/p/f${String(i).padStart(2, "0")}.lua`)
const bigCounts = Object.fromEntries(bigFiles.map((f) => [f, 4]))
const batches = api.commentBatches(bigFiles, bigCounts, 80, 60, 8)
check("big diff batches cover every file exactly once, in order", batches.flat(), [...bigFiles].sort())
check("big diff batches respect the weight cap",
  batches.every((b) => b.reduce((s, f) => s + 1 + bigCounts[f], 0) <= 60), true)
const hugeCounts = { "x/a.lua": 1, "x/huge.lua": 200 }
check("a file heavier than the cap gets a batch of its own",
  api.commentBatches(Object.keys(hugeCounts), hugeCounts, 80, 60, 8), [["x/a.lua"], ["x/huge.lua"]])

// ---- checklist accounting -------------------------------------------------------

const counts = { "a.lua": 2, "b.lua": 1 }
check("comment: distinct path:start entries per file must reach the count", api.unresolvedCommentCounts(counts, null, [
  { item: "a.lua:1-5", verdict: "passes", why: "x" },
  { item: "a.lua:1-5", verdict: "passes", why: "duplicate" },
  { item: "b.lua:3-9", verdict: "finding", why: "y" },
]), ["a.lua (1 of 2 comment blocks unresolved)"])
check("comment: files outside a batch scope are not required", api.unresolvedCommentCounts(counts, ["b.lua"], [
  { item: "b.lua:3-9", verdict: "passes", why: "y" },
]), [])

const ctx = { mergeBase: "abc123", commentBlockCounts: ["a.lua:2", "b.lua:1"] }
const unbatched = api.commentChecklistBlock({ commentChecklist: true }, ctx)
check("comment block states the in-scope count and the exact listing command", [
  unbatched.includes("adds 3 comment block(s)"),
  unbatched.includes("git diff --no-color --no-ext-diff --no-prefix -U0 abc123 HEAD -- '*.lua' | awk '"),
], [true, true])
const batched = api.commentChecklistBlock({ commentChecklist: true, batch: { index: 2, total: 3, files: ["b.lua"] } }, ctx)
check("batched comment block narrows count and pathspec to its files", [
  batched.includes("BATCH 2 of 3"),
  batched.includes("adds 1 comment block(s)"),
  batched.includes("-- 'b.lua' | awk"),
], [true, true, true])

// ---- lensPrecheck ---------------------------------------------------------------

check("it skips a plugin-only lens when nothing under plugins/ changed",
  api.lensPrecheck({ pluginOnly: true }, ["scripts/check-lua.sh", "docs/README.md"]), "precheck: no plugin changes in the diff")
check("it runs a plugin-only lens when a plugin file changed",
  api.lensPrecheck({ pluginOnly: true }, ["docs/README.md", "plugins/x/main.lua"]), null)
check("it never skips a lens that is not plugin-only",
  api.lensPrecheck({ pluginOnly: false }, ["docs/README.md"]), null)

// ---- the real gather command ----------------------------------------------------

// Run the awk over this repo's own history, so a regex the shipped awk cannot compile fails here
// rather than inside a finder.
const root = execFileSync("git", ["rev-parse", "--show-toplevel"], { cwd: __dirname, encoding: "utf8" }).trim()
const firstCommit = execFileSync("git", ["rev-list", "--max-parents=0", "HEAD"], { cwd: root, encoding: "utf8" }).trim().split("\n")[0]
const realDiff = execFileSync("git", ["diff", "--no-color", "--no-ext-diff", "--no-prefix", "-U0", firstCommit, "HEAD", "--", "*.lua"],
  { cwd: root, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 })
const realOut = runAwk(api.COMMENT_AWK, realDiff)
check("comment awk runs over this repo's Lua history and every line is path:start-end",
  realOut.length > 0 && realOut.every((l) => /^plugins\/[^:]+\.lua:\d+-\d+ \(/.test(l)), true)

console.log(failures ? `\n${failures} check(s) failed` : "\nALL PASS")
process.exit(failures ? 1 : 0)
