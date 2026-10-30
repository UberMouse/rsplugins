// Test for branch-code-review.js's grouped verify: folder grouping, the multi-verdict parser, and
// per-finding scoring from group votes.
//
// Run: node .claude/workflows/branch-code-review.verify.test.js
//
// Like the other workflow tests, this extracts the shipped code between markers and evaluates it,
// so a rename fails loudly rather than silently testing nothing.

const { grab, check, finish } = require("./branch-code-review.testlib.js")

const api = new Function(
  grab("verdict parsing", "// ---- verdict parsing", "const SYNTH_SCHEMA") +
  grab("grouped verify", "// ---- grouped verify", "// ---- end grouped verify") +
  "return { parseVerdicts, verifyGroups, scoreFinding, voteDecided, nextVoteRound, BAND_SCORE }")()
const { parseVerdicts, verifyGroups, scoreFinding, voteDecided, nextVoteRound, BAND_SCORE } = api

const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b)

const f = (file, line) => ({ file, line: String(line), summary: `${file}:${line}` })
const ids = (groups) => groups.map((g) => g.map((x) => `${x.file}:${x.line}`))

console.log("verifyGroups")
{
  const a = [f("plugins/a/x.lua", 3), f("plugins/a/x.lua", 1), f("plugins/a/y.lua", 9)]
  check("it keeps one folder's findings in one group, in file+line order",
    eq(ids(verifyGroups(a, 6)), [["plugins/a/x.lua:1", "plugins/a/x.lua:3", "plugins/a/y.lua:9"]]))

  const sib = [f("plugins/a/x.lua", 1), f("plugins/a/x.lua", 2), f("plugins/b/z.lua", 1), f("plugins/b/z.lua", 2), f("plugins/c/w.lua", 1)]
  check("it packs whole sibling folders together up to the cap", eq(verifyGroups(sib, 6).length, 1))

  const four = (dir) => [1, 2, 3, 4].map((l) => f(`${dir}/m.lua`, l))
  const g = verifyGroups([...four("plugins/a"), ...four("plugins/b")], 6)
  check("it never splits a folder that fits in a group to fill the previous one",
    eq(g.map((x) => x.length), [4, 4]) && g.every((x) => new Set(x.map((y) => y.file)).size === 1))

  const big = Array.from({ length: 13 }, (_, i) => f(`plugins/a/f${String(i).padStart(2, "0")}.lua`, 1))
  const sizes = verifyGroups(big, 6).map((x) => x.length)
  check("it splits an oversized folder into near-equal groups within the cap",
    sizes.every((n) => n <= 6) && sizes.reduce((s, n) => s + n, 0) === 13 && Math.max(...sizes) - Math.min(...sizes) <= 1,
    JSON.stringify(sizes))

  const many = [...big, f("plugins/b/q.lua", 1), f("x.lua", 1)]
  const flat = verifyGroups(many, 6).flat()
  check("it returns every finding exactly once", flat.length === many.length && new Set(flat).size === many.length)
  check("it returns no groups for no findings", eq(verifyGroups([], 6), []))
}

console.log("parseVerdicts")
{
  const keys = ["F1", "F2", "F3"]
  const r = parseVerdicts(
    '```json\n{"verdicts":[{"key":"F2","refuted":true,"band":"D","reasoning":"no"},{"key":"F1","refuted":false,"band":"B","matched":"a loop over LocList in one callback"}]}\n```',
    keys)
  check("it matches verdicts by key regardless of order", r.F1.band === "B" && r.F2.refuted === true)
  check("it derives confidence from the band", r.F1.confidence === BAND_SCORE.B && r.F2.confidence === 0)
  check("it keeps the matched band clause", r.F1.matched === "a loop over LocList in one callback")
  check("it leaves a key the verifier skipped as no verdict", r.F3 === null)

  const pos = parseVerdicts([{ refuted: false, band: "A" }, { refuted: "true" }, { band: "c" }], keys)
  check("it matches a keyless list by position when the lengths agree",
    pos.F1.band === "A" && pos.F2.refuted === true && pos.F3.band === "C")

  const short = parseVerdicts([{ refuted: false, band: "B" }], keys)
  check("it refuses to guess positions from a short keyless list", eq(short, { F1: null, F2: null, F3: null }))

  const wrapped = parseVerdicts({ input: JSON.stringify({ verdicts: [{ key: "F3", refuted: false, band: "A" }] }) }, keys)
  check("it unwraps the stringified `input` envelope", wrapped.F3 && wrapped.F3.band === "A")

  const byKey = parseVerdicts({ F1: { refuted: false, band: "B" } }, keys)
  check("it accepts an object keyed by finding key", byKey.F1.band === "B" && byKey.F2 === null)

  const numeric = parseVerdicts([{ confidence: 90 }, { confidence: "66" }, { confidence: 60 }], keys)
  check("it maps an off-schema numeric confidence onto the band it would sit in",
    numeric.F1.band === "A" && numeric.F2.band === "B" && numeric.F3.band === "C")
  const loose = parseVerdicts([{ band: "broken" }, { band: "band b" }, { band: "B — a loop over LocList in one callback" }], keys)
  check("it reads a band only when the whole value is one, never a word that starts with a band letter",
    loose.F1.band === "D" && loose.F2.band === "B" && loose.F3.band === "B")
  check("it defaults a verdict with neither band nor confidence to band D",
    parseVerdicts('{"verdicts":[{"key":"F1","refuted":false}]}', keys).F1.band === "D")
  check("it returns all-null for garbage", eq(parseVerdicts("no json here", keys), { F1: null, F2: null, F3: null }))
}

console.log("scoreFinding")
{
  const dim = { key: "comments", label: "Comments" }
  const v = (refuted, band) => ({ refuted, band, confidence: refuted ? 0 : BAND_SCORE[band], reasoning: "" })
  check("it drops a finding a majority refutes", scoreFinding(f("a", 1), dim, [v(true, "D"), v(true, "D")], "B") === null)
  const split = scoreFinding(f("a", 1), dim, [v(true, "D"), v(false, "B")], "B")
  check("it keeps a split refute and tiers on the non-refuting votes only",
    split.confidence === BAND_SCORE.B && split.tier === "primary")
  const halfDead = scoreFinding(f("a", 1), dim, [null, v(true, "D")], "B")
  check("it keeps a finding whose only verdict refutes it when another vote is missing, in the appendix",
    halfDead !== null && halfDead.tier === "appendix")
  const dead = scoreFinding(f("a", 1), dim, [null, undefined], "B")
  check("it keeps a finding with no verdicts as a zero-confidence appendix entry", dead.tier === "appendix" && dead.votes === 0)
  check("it routes a finding below the primary band to the appendix",
    scoreFinding(f("a", 1), dim, [v(false, "C"), v(false, "C")], "B").tier === "appendix")
  const bc = scoreFinding(f("a", 1), dim, [v(false, "B"), v(false, "C")], "B")
  check("it promotes a B/C split that averages below the bar, because half the votes clear it",
    bc.tier === "primary" && bc.confidence < BAND_SCORE.B && eq(bc.bands, ["B", "C"]))
  check("it demotes when only one of three votes clears the bar",
    scoreFinding(f("a", 1), dim, [v(false, "B"), v(false, "C"), v(false, "D")], "B").tier === "appendix")
  check("it lets band C into the main report when the effort's primary band is C",
    scoreFinding(f("a", 1), dim, [v(false, "C"), v(false, "C")], "C").tier === "primary")
}

console.log("voteDecided")
{
  const dim = { key: "rsapi", label: "RS API & Runtime Limits" }
  const v = (refuted, band) => ({ refuted, band, confidence: refuted ? 0 : BAND_SCORE[band] })
  check("it decides a finding whose first of two votes keeps it at the bar",
    voteDecided(f("a", 1), dim, [v(false, "B")], 2, "B") === true)
  check("it leaves open a finding whose first vote is below the bar, since a second can promote it",
    voteDecided(f("a", 1), dim, [v(false, "C")], 2, "B") === false)
  check("it leaves open a finding whose first vote refutes it, since a second refute drops it",
    voteDecided(f("a", 1), dim, [v(true, "D")], 2, "B") === false)
  check("it leaves open a finding whose first vote died",
    voteDecided(f("a", 1), dim, [null], 2, "B") === false)
  check("it never decides after one of three votes, since two later refutes still drop it",
    voteDecided(f("a", 1), dim, [v(false, "A")], 3, "B") === false)
  check("it decides at three votes once two keep it at the bar",
    voteDecided(f("a", 1), dim, [v(false, "A"), v(false, "B")], 3, "B") === true)
  check("it treats band C as clearing when the primary band is C",
    voteDecided(f("a", 1), dim, [v(false, "C")], 2, "C") === true)
  check("it is decided with every vote in", voteDecided(f("a", 1), dim, [v(false, "D"), v(false, "D")], 2, "B") === true)
}

console.log("nextVoteRound")
{
  const fs6 = Array.from({ length: 6 }, (_, i) => f(`plugins/a/m${i}.lua`, 1))
  const one = nextVoteRound([[0, 1, 2, 3, 4, 5]], new Set([0, 3]), fs6, 6)
  check("it re-runs a whole group with its cached prompt when that is cheaper than a new prompt",
    one.mode === "rerun" && eq(one.groups, [[0, 1, 2, 3, 4, 5]]))

  const many = Array.from({ length: 6 }, (_, i) => f(`plugins/${String.fromCharCode(97 + i)}/m.lua`, 1))
  const groups = [[0], [1], [2], [3], [4], [5]]
  const packed = nextVoteRound(groups, new Set([0, 1, 2, 3, 4, 5]), many, 6)
  check("it repacks open findings when that needs far fewer verifiers than re-running their groups",
    packed.mode === "repack" && packed.groups.length === 1 && eq(packed.groups[0].slice().sort(), [0, 1, 2, 3, 4, 5]))

  const skip = nextVoteRound([[0, 1], [2, 3]], new Set([2]), fs6.slice(0, 4), 6)
  check("it never re-runs a group whose findings are all decided", eq(skip.groups, [[2, 3]]))
}

finish()
