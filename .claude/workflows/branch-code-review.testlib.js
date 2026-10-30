// Shared helpers for the branch-code-review.*.test.js files (CommonJS, so `node <file>` runs them).
//
// The tests evaluate spans of the shipped script rather than copies of it, so grab() is the one
// way they reach its code: a moved or renamed marker must fail loudly, not test nothing.

const fs = require("fs")
const path = require("path")

const SCRIPT = path.join(__dirname, "branch-code-review.js")
const src = fs.readFileSync(SCRIPT, "utf8")

let failures = 0

// The shipped text from `start` up to (not including) the next `end` after it. `label` names the
// block in the error so a stale marker points at the test to update.
function grab(label, start, end) {
  const a = src.indexOf(start)
  const b = src.indexOf(end, a)
  if (a < 0 || b < 0) {
    throw new Error(
      `branch-code-review.js no longer contains the marker ${JSON.stringify(start)} ` +
      `followed by ${JSON.stringify(end)} — the ${label} block moved or was renamed. ` +
      "Update this test's markers rather than deleting the test.")
  }
  return src.slice(a, b)
}

// Records one assertion; `detail` is printed only on failure.
function check(name, ok, detail) {
  if (!ok) failures++
  console.log(`  ${ok ? "PASS" : "FAIL"}  ${name}${ok || !detail ? "" : " — " + detail}`)
}

// check() for deep-equal values (compared as JSON), showing both on failure.
function checkEq(name, actual, expected) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  check(name, a === e, `expected ${e}, actual ${a}`)
}

// Prints the summary and exits 1 if any check failed, so a caller (or the gate) sees the failure.
function finish() {
  console.log(failures ? `\n${failures} FAILURE(S)` : "\nALL PASS")
  process.exit(failures ? 1 : 0)
}

module.exports = { src, grab, check, checkEq, finish }
