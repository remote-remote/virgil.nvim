-- An agent picking up a trail a person started: `show --json`, then `create`
-- with the draft it printed.
local store = require("virgil.store")
local S = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/support.lua")

local LINES = {
  "local M = {}",
  "function M.one() return 1 end",
  "function M.two() return 2 end",
  "  return nil",
  "function M.three()",
  "  return nil",
  "end",
  "return M",
}

-- A person's trail: a written step, a stub, and a step scoped by a symbol.
local function with_human_trail(fn)
  local root = S.repo({ ["a.lua"] = LINES })
  local ok, err = xpcall(function()
    local file = store.trails_dir(root) .. "/mine.json"
    assert(store.create(file, {
      id = "mine", title = "Mine", root = root,
      steps = {
        { path = "a.lua", title = "One", range = { 2, 2 }, anchor = { text = LINES[2] }, note = "Returns one." },
        { path = "a.lua", title = "", range = { 3, 3 }, anchor = { text = LINES[3] }, note = "" },
        { path = "a.lua", title = "Nil", range = { 6, 7 }, anchor = { text = LINES[6], symbol = "M.three" }, note = "Nothing." },
      },
    }))
    fn(root, file)
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end

local function show_json(root, id)
  local code, out, stderr = S.cli(root, { "show", id, "--json", "--root", root })
  T.eq(code, 0, stderr)
  return vim.json.decode(out, { luanil = { object = true } })
end

local function without_stamps(raw)
  local data = vim.json.decode(raw)
  data.rev, data.updated_by, data.updated_at = nil, nil, nil
  return data
end

T.test("agent: show --json prints a draft with rev and anchors", function()
  with_human_trail(function(root)
    local draft = show_json(root, "mine")
    T.eq(draft.id, "mine")
    T.eq(draft.rev, 1)
    T.eq(draft.updated_by.kind, "human")
    T.eq(draft.steps[3].anchor, { text = LINES[6], symbol = "M.three" })
    T.eq(draft.steps[2].note, "")
  end)
end)

T.test("agent: a person's trail survives a CLI round trip unchanged", function()
  with_human_trail(function(root, file)
    local before = S.read(file)
    local draft = vim.json.encode(show_json(root, "mine"))
    local code, out, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, draft)
    T.eq(code, 0, stderr)
    T.ok(stderr:match("step 2 is a stub with no title or note yet"), stderr)
    T.ok(out:match("rev 2"), out)
    local after = S.read(file)
    T.eq(without_stamps(after), without_stamps(before))
    local data = vim.json.decode(after)
    T.eq({ data.author.kind, data.updated_by.kind }, { "human", "agent" })
  end)
end)

T.test("agent: a supplied anchor is followed when the code moved", function()
  with_human_trail(function(root, file)
    local draft = show_json(root, "mine")
    local moved = vim.list_extend({ "-- a header", "" }, LINES)
    vim.fn.writefile(moved, root .. "/a.lua")
    draft.steps[1].note = "Returns one, always."
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, vim.json.encode(draft))
    T.eq(code, 0, stderr)
    T.ok(stderr:match("step 1: moved from line 2 to 4"), stderr)
    local data = vim.json.decode(S.read(file))
    T.eq(data.steps[1].range, { 4, 4 })
    T.eq(data.steps[1].anchor, { text = LINES[2] })
    T.eq(data.steps[1].note, "Returns one, always.")
  end)
end)

T.test("agent: a supplied anchor that is gone or ambiguous is refused", function()
  with_human_trail(function(root, file)
    local before = S.read(file)
    local draft = show_json(root, "mine")
    local changed = vim.deepcopy(LINES)
    changed[2] = "function M.one() return 11 end"
    vim.fn.writefile(changed, root .. "/a.lua")
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, vim.json.encode(draft))
    T.eq(code, 1)
    T.ok(stderr:match("step 1: its anchor text .- is no longer in a%.lua"), stderr)
    T.eq(S.read(file), before)

    vim.fn.writefile(vim.list_extend({ "" }, LINES), root .. "/a.lua")
    code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, vim.json.encode(draft))
    T.eq(code, 1)
    T.ok(stderr:match("step 3: its anchor text .- is at 2 places in a%.lua, none of them line 6"), stderr)

    -- Dropping the anchor re-traces the step from its range.
    draft.steps[3].anchor = nil
    draft.steps[3].range = { 7, 8 }
    draft.steps[3].symbol = "M.three"
    code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, vim.json.encode(draft))
    T.eq(code, 0, stderr)
    T.eq(vim.json.decode(S.read(file)).steps[3].anchor, { text = "  return nil", symbol = "M.three" })
  end)
end)

T.test("agent: stubs are written with a warning", function()
  local root = S.repo({ ["a.lua"] = LINES })
  local ok, err = xpcall(function()
    local draft = vim.json.encode({ title = "Pins", steps = {
      { path = "a.lua", range = { 2, 2 }, title = "One", note = "" },
      { path = "a.lua", range = { 3, 3 }, note = "Two has a note." },
    } })
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--new" }, draft)
    T.eq(code, 0, stderr)
    T.ok(stderr:match("step 1 has no note yet"), stderr)
    T.ok(stderr:match("step 2: no title"), stderr)
    local data = assert(store.read(store.trails_dir(root) .. "/pins.json"))
    T.eq(data.steps[1].note, "")
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)
