-- End-to-end smoke test: plugins/var-dump as it starts up without httpAccess. The granted path
-- needs id.* and the full var scan, which the harness doesn't model.

local harness = require("tests.harness")

describe("plugins/var-dump without httpAccess", function()
    it("loads its json module, says how to grant access and sends nothing", function()
        local h = harness.load("var-dump")
        assert.are.equal(
            "[VARDUMP] waiting for httpAccess: run `ppr var-dump`, then `ppe var-dump httpAccess`",
            h:output()
        )
        h:advance(1200)
        assert.are.equal(0, #h.requests)
    end)

    it("is reloadable", function()
        local h = harness.load("var-dump")
        h:reload() -- faults if the old instance kept a subscription
        assert.are.equal(2, #h.console)
    end)
end)
