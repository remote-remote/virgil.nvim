local capture = require("virgil.capture")
local store = require("virgil.store")
local S = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/support.lua")

local LUA = {
  "local M = {}",
  "",
  "function M.login(user)",
  "  local ok = check(user)",
  "  return ok",
  "end",
  "",
  "function M.logout(user)",
  "  local ok = check(user)",
  "  return ok",
  "end",
  "",
  "return M",
}

local function with_buffer(fn)
  local root = S.repo({ ["auth.lua"] = LUA })
  local ok, err = xpcall(function()
    local buf = vim.fn.bufadd(root .. "/auth.lua")
    vim.fn.bufload(buf)
    fn(root, buf)
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end

T.test("capture: trims blank lines and anchors to the first line picked", function()
  with_buffer(function(root, buf)
    local loc = assert(capture.location(buf, 2, 7, root))
    T.eq(loc.path, "auth.lua")
    T.eq(loc.range, { 3, 6 })
    T.eq(loc.anchor, { text = "function M.login(user)" })
    T.eq(loc.warnings, {})
    -- A backwards selection is the same lines.
    T.eq(assert(capture.location(buf, 6, 3, root)).range, { 3, 6 })
  end)
end)

T.test("capture: refuses blank lines, non-file buffers and files outside the root", function()
  with_buffer(function(root, buf)
    local loc, err = capture.location(buf, 2, 2, root)
    T.eq(loc, nil)
    T.ok(tostring(err):match("only blank lines"), err)

    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    T.ok(select(2, capture.location(scratch, 1, 1, root)):match("not a file buffer"))
    vim.api.nvim_buf_delete(scratch, { force = true })

    T.ok(select(2, capture.location(buf, 3, 3, root .. "/elsewhere")):match("outside the trail root"))
  end)
end)

T.test("capture: a repeated first line is scoped by its enclosing symbol", function()
  with_buffer(function(root, buf)
    local loc = assert(capture.location(buf, 9, 10, root))
    T.eq(loc.anchor, { text = "  local ok = check(user)", symbol = "M.logout" })
    T.eq(loc.warnings, {})
  end)
end)

T.test("capture: unsaved text still anchors, with a warning", function()
  with_buffer(function(root, buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "-- not on disk yet" })
    local loc = assert(capture.location(buf, 1, 1, root))
    T.eq(loc.anchor.text, "-- not on disk yet")
    T.eq(#loc.warnings, 1)
    T.ok(loc.warnings[1]:match("unsaved"), loc.warnings[1])
  end)
end)

T.test("capture: new trail ids follow the CLI's slug and never collide", function()
  T.eq(capture.slug("How a Login becomes a Session!"), "how-a-login-becomes-a-session")
  T.eq(capture.slug("  ***  "), "trail")
  T.eq(capture.slug(("word "):rep(30)), ("word-"):rep(9) .. "wor")
  T.eq(capture.slug(("abc "):rep(12) .. "x"), ("abc-"):rep(11) .. "abc")
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  T.eq(select(2, capture.new_path(dir, "Auth")), "auth")
  S.write(dir .. "/auth.json", "{}")
  S.write(dir .. "/auth-2.json", "{}")
  local path, id = capture.new_path(dir, "Auth")
  T.eq({ path, id }, { dir .. "/auth-3.json", "auth-3" })
  vim.fn.delete(dir, "rf")
end)

T.test("capture: the CLI slugs a title the same way", function()
  local root = S.repo({ ["auth.lua"] = LUA })
  local ok, err = xpcall(function()
    local title = "Why ~Auth~ fails: 3 reasons (and 1 fix)"
    local draft = vim.json.encode({ title = title, steps = {
      { path = "auth.lua", range = { 3, 3 }, title = "t", note = "n" },
    } })
    local code, _, stderr = S.cli(root, { "create", "--root", root }, draft)
    T.eq(code, 0, stderr)
    T.ok(vim.uv.fs_stat(store.trails_dir(root) .. "/" .. capture.slug(title) .. ".json"), capture.slug(title))
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end)
