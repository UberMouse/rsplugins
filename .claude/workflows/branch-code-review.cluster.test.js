// Test for branch-code-review.js's candidate-duplicate clustering.
//
// Run: node .claude/workflows/branch-code-review.cluster.test.js
//
// There is no test harness for workflow scripts, so this extracts the clustering block
// straight out of branch-code-review.js and evaluates it — the shipped code is what runs,
// and a rename of any extracted marker fails the test loudly rather than silently passing.
//
// The fixtures are real findingsList shapes from two runs of the kawaka workflow this one was
// ported from, with paths and lens names renamed, trimmed to the fields clustering reads. The
// clustering only looks at file, line and dimension, so their origin does not matter.

const { grab, check, finish } = require("./branch-code-review.testlib.js")

// One shipped span, ending where the report phase starts. `log` is a workflow builtin the block
// calls only to announce clusters, so it is passed in rather than spliced into the code.
const clusteringLogic = grab("clustering", "const CLUSTER_PROXIMITY_LINES", "\nphase(\"Report\")")

const cluster = (findingsList) =>
  new Function("findingsList", "log", clusteringLogic + "; return dupCandidates;")(findingsList, () => {})

const block = (findingsList) =>
  new Function("findingsList", "log", clusteringLogic + "; return dupBlock;")(findingsList, () => {})

// --- fixtures ----------------------------------------------------------------------

const f = (id, dimension, file, line) => ({ id, dimension, file, line })

// An effort=medium run. W4/W5 and I6/I7 each shipped as two separate findings.
const RUN_MEDIUM = [
  f("W1", "architecture", "plugins/x/MultiLayerSection.lua", "60-74"),
  f("W2", "rsapi", "plugins/x/RowOptions.lua", "120"),
  f("W3", "rsapi", "plugins/x/GeometrySwatch.lua", "123-152"),
  f("W4", "architecture", "plugins/x/ShowHideOpacity.lua", "16"),
  f("W5", "grounding", "plugins/x/ShowHideOpacity.lua", "16"),
  f("I1", "cleanup", "plugins/x/GeometrySwatch.lua", "45-70"),
  f("I2", "architecture", "plugins/x/GeometrySwatch.lua", "52-53, 135-136"),
  f("I3", "grounding", "plugins/x/LayerRow.lua", "135-140"),
  f("I4", "correctness", "plugins/x/mapDatasetCapabilities.lua", "12"),
  f("I5", "correctness", "plugins/x/objectCreators.lua", "227"),
  f("I6", "architecture", "plugins/x/objectCreators.lua", "230, 252, 283, 306, 335"),
  f("I7", "cleanup", "plugins/x/objectCreators.lua", "230, 252, 283, 306, 335"),
]

// An effort=max run. I6/I7 shipped twice again, this time with anchors 11 lines
// apart — which is why an exact file+line match is not a sufficient trigger.
const RUN_MAX = [
  f("W1", "comments", "plugins/x/rowGeometry.lua", "2936-2949"),
  f("W8", "comments", "plugins/x/rowGeometry.lua", "2964-2992"),
  f("I2", "comments", "plugins/x/rowGeometry.lua", "2994-3178"),
  f("W4", "correctness", "plugins/x/RowDetail.lua", "189"),
  f("I11", "comments", "plugins/x/RowDetail.lua", "95-98"),
  f("W5", "rsapi", "plugins/x/hydrateMapDatasets.lua", "152"),
  f("I14", "architecture", "plugins/x/hydrateMapDatasets.lua", "158"),
  f("I6", "cleanup", "plugins/x/objectCreators.lua", "219"),
  f("I7", "architecture", "plugins/x/objectCreators.lua", "230"),
  f("I13", "correctness", "plugins/x/objectCreators.lua", "230"),
]

// --- assertions --------------------------------------------------------------------

const idSets = (cs) => cs.map((c) => c.map((x) => x.id))
const together = (cs, ...ids) => idSets(cs).some((s) => ids.every((id) => s.includes(id)))
const apart = (cs, a, b) => !together(cs, a, b)

console.log("clustering: effort=medium run")
{
  const cs = cluster(RUN_MEDIUM)
  check("W4+W5 clustered (same file, IDENTICAL line, two lenses)", together(cs, "W4", "W5"))
  check("I6+I7 clustered (same file, identical multi-line anchors)", together(cs, "I6", "I7"))
  check("LayerRow finding left alone (only finding in its file)",
    !idSets(cs).flat().includes("I3"))
}

console.log("clustering: effort=max run")
{
  const cs = cluster(RUN_MAX)
  check("I6+I7 clustered despite anchors 11 lines apart", together(cs, "I6", "I7"))
  check("W1/W8/I2 NOT clustered — all one dimension, so presumed distinct",
    apart(cs, "W1", "W8") && apart(cs, "W8", "I2"))
  check("W4+I11 NOT clustered — same file but 91 lines apart",
    apart(cs, "W4", "I11"))
}

console.log("invariants (both runs)")
for (const [label, run] of [["medium", RUN_MEDIUM], ["max", RUN_MAX]]) {
  const cs = cluster(run)
  const flat = idSets(cs).flat()
  check(`${label}: no id appears in two clusters`, new Set(flat).size === flat.length)
  const known = new Set(run.map((x) => x.id))
  check(`${label}: every clustered id is a real finding`, flat.every((id) => known.has(id)))
  check(`${label}: every cluster has at least two members`, cs.every((c) => c.length > 1))
}

console.log("edge cases")
{
  check("a missing/unparseable line never clusters", cluster([
    f("A", "rsapi", "plugins/x/x.lua", undefined),
    f("B", "cleanup", "plugins/x/x.lua", "passim"),
    f("C", "grounding", "plugins/x/x.lua", ""),
  ]).length === 0)
  check("different files never cluster", cluster([
    f("A", "rsapi", "plugins/x/x.lua", "10"),
    f("B", "cleanup", "plugins/x/y.lua", "10"),
  ]).length === 0)
  check("an en-dash range parses like a hyphen range", together(cluster([
    f("A", "rsapi", "plugins/x/x.lua", "10–20"),
    f("B", "cleanup", "plugins/x/x.lua", "25"),
  ]), "A", "B"))
  check("beyond the proximity window, no cluster", cluster([
    f("A", "rsapi", "plugins/x/x.lua", "10"),
    f("B", "cleanup", "plugins/x/x.lua", "400"),
  ]).length === 0)
}

// The prompt block must always have a referent. An empty block leaves task 2's "the clusters
// listed above" pointing at nothing, which invites the agent to invent one or narrate its
// absence — both were raised in review of this change.
console.log("prompt block")
{
  const none = block([
    f("A", "rsapi", "plugins/x/x.lua", "10"),
    f("B", "cleanup", "plugins/x/y.lua", "10"),
  ])
  check("with no clusters, the block is non-empty and says none",
    none.trim().length > 0 && /none/i.test(none))
  check("with no clusters, the block forbids inventing them",
    /do not invent/i.test(none))

  const some = block(RUN_MAX)
  check("with clusters, every clustered id appears in the block",
    idSets(cluster(RUN_MAX)).flat().every((id) => some.includes(id)))
  check("with clusters, the block does not also claim none",
    !/— none\./i.test(some))
  check("the block names each finding's dimension so the agent can weigh the overlap",
    some.includes("cleanup") && some.includes("architecture"))
}

finish()
