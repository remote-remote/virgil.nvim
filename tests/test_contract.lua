-- The write contract shared by the plugin and bin/virgil (README: "Trail file
-- format and write rules"). Each test runs both implementations.
local store = require("virgil.store")
local S = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/support.lua")

local fixtures = vim.fn.glob(S.tests_dir .. "/fixtures/contract/*.json", false, true)
table.sort(fixtures)

local function python_verdicts(paths)
  local cmd = { "python3", S.tests_dir .. "/contract.py" }
  vim.list_extend(cmd, paths)
  local r = vim.system(cmd, { text = true }):wait()
  T.eq(r.code, 0, r.stderr)
  return vim.json.decode(r.stdout, { luanil = { object = true } })
end

local function lua_verdict(path)
  local data = vim.json.decode(S.read(path))
  local err = store.check(data)
  return { error = err, encoded = not err and store.encode(data) or nil }
end

local LINES = { "local M = {}", "", "function M.login(user)", "  local token = mint(user)", "  return token", "end", "", "return M" }

local function draft(extra)
  return vim.json.encode(vim.tbl_extend("force", {
    id = "auth", title = "Auth",
    steps = {
      { path = "auth.lua", range = { 3, 5 }, title = "Login", note = "The token is minted here." },
      { path = "auth.lua", range = { 8, 8 }, title = "Export", note = "Only M leaves." },
    },
  }, extra or {}))
end

T.test("contract: both validators give every fixture the same verdict", function()
  local py = python_verdicts(fixtures)
  for _, path in ipairs(fixtures) do
    local name = vim.fs.basename(path)
    local lua = lua_verdict(path)
    T.eq(lua.error, py[path].error, name)
    T.eq(lua.error == nil, name:match("^valid%-") ~= nil, name .. ": verdict matches its name")
  end
end)

T.test("contract: both encoders write the same bytes for every valid fixture", function()
  local py = python_verdicts(fixtures)
  local compared = 0
  for _, path in ipairs(fixtures) do
    local lua = lua_verdict(path)
    if lua.encoded then
      T.eq(lua.encoded, py[path].encoded, vim.fs.basename(path))
      compared = compared + 1
    end
  end
  T.ok(compared >= 3, "compared the valid fixtures")
end)

T.test("contract: the encoder keeps slashes, unicode and empty objects readable", function()
  local out = store.encode(vim.json.decode(S.read(S.tests_dir .. "/fixtures/contract/valid-extras-and-escapes.json")))
  T.ok(out:find('"path": "src/auth.ts"', 1, true), "slashes are not escaped")
  T.ok(out:find("é", 1, true), "unicode is written as is")
  T.ok(out:find('"weird": {}', 1, true), "an empty object stays an object")
  T.ok(out:find('"extra": []', 1, true), "an empty array stays an array")
  T.ok(out:find('\\u0001', 1, true), "control characters are escaped")
end)

T.test("contract: a plugin-written trail loads in the CLI and survives its round trip", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/pinned.json"
    local data = assert(store.create(path, {
      id = "pinned", title = "Pinned by hand", root = root,
      steps = { { path = "auth.lua", range = { 4, 4 }, anchor = { text = LINES[4] }, note = "" } },
    }))
    T.eq(data.rev, 1)
    T.eq(data.author.kind, "human")
    local written = S.read(path)

    local code, out, stderr = S.cli(root, { "show", "pinned", "--root", root })
    T.eq(code, 0, stderr)
    T.ok(out:match("rev 1, last edited by human"), out)

    code, _, stderr = S.cli(root, { "cursor", "pinned", "1", "--root", root })
    T.eq(code, 0, stderr)
    T.eq(S.read(path), written, "the CLI rewrote the file byte for byte")
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)

T.test("contract: create counts revisions and keeps the creator", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/auth.json"
    local code, out, stderr = S.cli(root, { "create", "--root", root, "--author", "claude" }, draft())
    T.eq(code, 0, stderr)
    T.ok(out:match("rev 1%)"), out)
    local first = vim.json.decode(S.read(path))
    T.eq({ first.rev, first.author, first.updated_by.kind }, { 1, { kind = "agent", name = "claude" }, "agent" })

    local edited = vim.deepcopy(first)
    edited.author = { kind = "human", name = "rem" }
    edited.custom = { kept = true }
    S.write(path, store.encode(edited))
    code, out, stderr = S.cli(root, { "create", "--root", root, "--author", "other" }, draft())
    T.eq(code, 0, stderr)
    local second = vim.json.decode(S.read(path))
    T.eq(second.rev, 2)
    T.eq(second.author, { kind = "human", name = "rem" }, "the creator is kept")
    T.eq(second.updated_by, { kind = "agent", name = "other" })
    T.eq(second.created_at, first.created_at)
    T.eq(second.custom, { kept = true }, "fields the CLI does not know survive")
    T.eq(vim.fn.glob(store.trails_dir(root) .. "/*.tmp", false, true), {}, "no temp file is left")
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)

T.test("contract: create refuses stale revisions, existing ids, and people's trails", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/auth.json"
    T.eq((S.cli(root, { "create", "--root", root, "--new" }, draft())), 0)

    local code, _, stderr = S.cli(root, { "create", "--root", root, "--new" }, draft())
    T.eq(code, 1)
    T.ok(stderr:match("already exists"), stderr)

    code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "0" }, draft())
    T.eq(code, 1)
    T.ok(stderr:match("changed since rev 0 %(now 1"), stderr)

    -- A person edits the trail in the plugin.
    assert(store.save(path, 1, function(data) data.steps[1].note = "Edited by hand." end))
    local before = S.read(path)
    code, _, stderr = S.cli(root, { "create", "--root", root }, draft())
    T.eq(code, 1)
    T.ok(stderr:match("last edited by a person"), stderr)
    T.eq(S.read(path), before, "nothing was written")

    code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "2" }, draft())
    T.eq(code, 0, stderr)
    T.eq(vim.json.decode(S.read(path)).rev, 3)
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)

T.test("contract: save bumps rev, stamps the editor, and carries anchors through", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/auth.json"
    T.eq((S.cli(root, { "create", "--root", root }, draft())), 0)
    local before = vim.json.decode(S.read(path))
    -- A stale anchor must survive an unrelated edit untouched: only a
    -- re-capture may change it.
    before.steps[2].anchor.text = "stale text the file no longer has"
    S.write(path, store.encode(before))

    local saved = assert(store.save(path, 1, function(data) data.steps[1].title = "Minted" end))
    T.eq(saved.rev, 2)
    T.eq(saved.__file, path)
    T.eq(saved.updated_by.kind, "human")
    T.eq(saved.author, before.author)
    T.eq(saved.created_at, before.created_at)
    T.eq(saved.steps[2].anchor.text, "stale text the file no longer has")
    T.eq(saved.steps[1].title, "Minted")

    local stale, why, kind = store.save(path, 1, function() end)
    T.eq(stale, nil)
    T.eq(kind, "conflict")
    T.ok(why:match("rev 2"), why)

    local bad, _, bad_kind = store.save(path, 2, function(data) data.steps = {} end)
    T.eq({ bad, bad_kind }, { nil, "invalid" })
    T.eq(vim.json.decode(S.read(path)).rev, 2, "an invalid change writes nothing")
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)

T.test("contract: the cursor write is atomic and does not bump rev", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/auth.json"
    T.eq((S.cli(root, { "create", "--root", root }, draft())), 0)
    local data = assert(store.read(path))
    local inode = assert(vim.uv.fs_stat(path)).ino
    T.ok(store.write_cursor(data, 1))
    T.ok(assert(vim.uv.fs_stat(path)).ino ~= inode, "written through a rename")
    local after = vim.json.decode(S.read(path))
    T.eq({ after.cursor, after.rev }, { 1, 1 })
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)

T.test("contract: create refuses an existing file and never overwrites it", function()
  local root = S.repo({ ["auth.lua"] = LINES })
  local ok, err = xpcall(function()
    local path = store.trails_dir(root) .. "/auth.json"
    T.eq((S.cli(root, { "create", "--root", root }, draft())), 0)
    local before = S.read(path)
    local data, why = store.create(path, {
      id = "auth", title = "Mine", root = root,
      steps = { { path = "auth.lua", range = { 4, 4 }, anchor = { text = LINES[4] }, note = "" } },
    })
    T.eq(data, nil)
    T.ok(why:match("already exists"), why)
    T.eq(S.read(path), before)
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)
