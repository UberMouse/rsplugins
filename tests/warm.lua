-- busted helper (.busted): runs once, before busted insulates each spec file. busted drops the
-- modules a spec file requires when it ends, but keeps the ones a helper required, so the harness
-- parses vars.csv, the docs/api/consts config tables and the API stubs once per run instead of
-- once per file. Everything warmed here is shared across specs: treat it as read-only.
local catalog = require("tests.harness.catalog")
local stubs = require("tests.harness.stubs")

-- Priming through the public lookups fills catalog's vars and per-kind config caches. The keys
-- need not exist; the lookup parses its file either way.
catalog.var("VarPlayer", 0)
for _, kind in ipairs({ "Inv", "Obj", "Sound", "Font", "Sprite", "Cursor" }) do
    catalog.config(kind, 0)
end
stubs.index()
