-- Commands from scripts/rsdev.py and their results, as the dev bridge and dev/remote share them
-- (dev tools, never submitted): parsing the daemon's reply into commands, compiling a snippet,
-- collecting what it prints, and encoding a result under size caps. Nothing here calls the API
-- or keeps state; each caller passes its own `limits`:
--
--   valueBytes   encoded values of one result
--   outputLines  print/log lines one result keeps
--   lineBytes    one output line or error
--   resultBytes  one encoded result
--
-- The wire format is docs/dev-environment.md ("Protocol" under "Dev bridge").

local json = require("dev/json")
local batch = require("dev/batch")

local command = {}

-- A reply line's arg escapes backslash, tab, newline and CR (rsdev.py escape_arg). An unknown
-- escape is left as written, as test_rsdev.py's unescape_arg does.
local UNESCAPES = { ["\\"] = "\\", t = "\t", n = "\n", r = "\r" }

---@param text string
---@return string
function command.unescape(text)
    return (text:gsub("\\(.)", function(c)
        return UNESCAPES[c] or ("\\" .. c)
    end))
end

-- The commands in a reply: zero or more `<id>\t<kind>\t<arg>` lines, each ending in a newline.
-- Returns the commands ({ id, kind, arg }, arg unescaped) and the malformed lines, which can't
-- be answered because they have no usable id. A non-empty body that doesn't end in a newline
-- was cut short, so the whole reply is refused: returns nil and why.
---@param body string
---@return { id: string, kind: string, arg: string }[]?
---@return string[] | string
function command.parseReply(body)
    if body ~= "" and body:sub(-1) ~= "\n" then return nil, "reply does not end in a newline" end
    local commands, malformed = {}, {}
    for line in body:gmatch("([^\n]*)\n") do
        local id, kind, arg = line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)$")
        local idOk = id ~= nil and #id <= 32 and id:match("^[%w_-]+$") ~= nil
        if idOk and kind ~= "" then
            commands[#commands + 1] = { id = id, kind = kind, arg = command.unescape(arg) }
        else
            malformed[#malformed + 1] = line
        end
    end
    return commands, malformed
end

-- The oldest results whose bytes fit in `maxBytes` (at least one, however big), and the rest.
---@param results string[]
---@param maxBytes integer
---@return string[] taken
---@return string[] rest
function command.takeResults(results, maxBytes)
    local taken, rest, bytes = {}, {}, 0
    for _, result in ipairs(results) do
        if #rest == 0 and (#taken == 0 or bytes + #result <= maxBytes) then
            taken[#taken + 1] = result
            bytes = bytes + #result
        else
            rest[#rest + 1] = result
        end
    end
    return taken, rest
end

-- A snippet compiled in `env`: as `return <source>` first, so an expression gives its values,
-- then as statements. Returns the chunk, or nil and the compile error. `compile` is `load`
-- (the client honours its mode and env arguments, docs/api-concepts.md).
---@param compile function?
---@param source string
---@param env table
---@return function?
---@return string?
function command.compile(compile, source, env)
    if type(compile) ~= "function" then
        return nil, "this client has no load(), so eval can't run Lua"
    end
    local chunk, err = compile("return " .. source, "=eval", "t", env)
    if not chunk then
        chunk, err = compile(source, "=eval", "t", env)
    end
    return chunk, err
end

-- What one snippet has printed so far.
---@return { lines: string[], truncated: boolean }
function command.newOutput()
    return { lines = {}, truncated = false }
end

-- Add a printed line, keeping at most outputLines lines of at most lineBytes each.
---@param output { lines: string[], truncated: boolean }
---@param text string
---@param limits table
function command.addOutput(output, text, limits)
    if #output.lines >= limits.outputLines then
        output.truncated = true
        return
    end
    local max = limits.lineBytes
    if #text > max then
        text, output.truncated = text:sub(1, max), true
    end
    output.lines[#output.lines + 1] = text
end

-- One command's result, encoded for a sync or tee body. `r.error` (any value) is set when
-- `r.ok` is false. An eval adds `output`, and on success `values` (each already serialised,
-- with `nvalues` of them, nils included). The values go as a JSON array of exactly nvalues
-- elements, nils as null (dev/json would write a table with a nil hole as an object). Past
-- valueBytes they are dropped; a result still over resultBytes loses its output; either sets
-- truncated, as does a cut error or output line.
---@param r { id: string, ok: boolean, error: any, values: any[]?, nvalues: integer?, output: { lines: string[], truncated: boolean }? }
---@param limits table
---@return string
function command.resultEntry(r, limits)
    local meta = { id = r.id, ok = r.ok }
    local truncated = r.output ~= nil and r.output.truncated
    if not r.ok then
        local cut
        meta.error, cut = batch.cap(batch.text(r.error), limits.lineBytes)
        truncated = truncated or cut
    end
    meta.output = r.output and r.output.lines
    local values = nil ---@type string[]?
    if r.nvalues then
        meta.nvalues = r.nvalues
        local parts, bytes = {}, 0
        for i = 1, r.nvalues do
            parts[i] = json.encode((r.values or {})[i])
            bytes = bytes + #parts[i] + 1
        end
        if bytes > limits.valueBytes then
            parts, truncated = {}, true
        end
        values = parts
    end
    local function encode()
        meta.truncated = truncated or nil
        if not values then return json.encode(meta) end
        return batch.batchBody(meta, values, "values")
    end
    local entry = encode()
    if #entry > limits.resultBytes and meta.output then
        meta.output, truncated = {}, true
        entry = encode()
    end
    return entry
end

return command
