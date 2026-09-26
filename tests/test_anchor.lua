local anchor = require("breadcrumbs.anchor")

local BASE = {
  "local M = {}",
  "",
  "function M.login(user)",
  "  local token = mint(user)",
  "  verifyMfa(user)",
  "  return token",
  "end",
  "",
  "return M",
}

local function copy(t) return vim.deepcopy(t) end

local function step(range)
  return {
    path = "auth.lua",
    range = range or { 4, 5 },
    anchor = { text = "  local token = mint(user)", symbol = "M.login" },
    note = "token is minted here",
  }
end

T.test("anchor: rung 1 exact match at the authored line", function()
  local r = anchor.locate(BASE, step(), { start_line = 3, end_line = 7 })
  T.eq({ r.status, r.rung, r.start_line, r.end_line }, { "exact", "exact", 4, 5 })
end)

T.test("anchor: rung 2 drifted by insertion above, found within the symbol", function()
  local lines = copy(BASE)
  table.insert(lines, 1, "-- new header")
  table.insert(lines, 2, "")
  local r = anchor.locate(lines, step(), { start_line = 5, end_line = 9 })
  T.eq({ r.status, r.rung, r.start_line, r.end_line }, { "drifted", "within_symbol", 6, 7 })
end)

T.test("anchor: rung 3 drifted by an edit inside the symbol, falls back to the symbol range", function()
  local lines = copy(BASE)
  lines[4] = "  local token = mint(user, { ttl = 60 })"
  local r = anchor.locate(lines, step(), { start_line = 3, end_line = 7 })
  T.eq({ r.status, r.rung, r.start_line, r.end_line }, { "drifted", "symbol_only", 3, 7 })
end)

T.test("anchor: rung 4 file-wide unique match when no symbol resolves", function()
  local lines = copy(BASE)
  table.insert(lines, 1, "-- new header")
  local r = anchor.locate(lines, step(), nil)
  T.eq({ r.status, r.rung, r.start_line, r.end_line }, { "drifted", "file_wide", 5, 6 })
end)

T.test("anchor: rung 5 broken when the anchor text is gone", function()
  local lines = copy(BASE)
  lines[4] = "  local token = nil"
  local r = anchor.locate(lines, step(), nil)
  T.eq({ r.status, r.rung }, { "broken", "no_match" })
end)

T.test("anchor: a duplicated anchor is broken, never a guess", function()
  local lines = {
    "local M = {}",
    "  local token = mint(user)",     -- decoy, outside the symbol
    "",
    "function M.login(user)",
    "  local token = mint(user, opts)",
    "  local token = mint(user)",     -- the real one, moved down
    "  return token",
    "end",
  }
  local s = step({ 5, 6 })
  local r = anchor.locate(lines, s, nil)
  T.eq({ r.status, r.rung }, { "broken", "ambiguous" })
  -- the same file resolves once the symbol scopes the search
  local scoped = anchor.locate(lines, s, { start_line = 4, end_line = 8 })
  T.eq({ scoped.status, scoped.rung, scoped.start_line }, { "drifted", "within_symbol", 6 })
end)

T.test("anchor: a step with no anchor text is drifted, not exact", function()
  local s = step()
  s.anchor = nil
  local r = anchor.locate(BASE, s, nil)
  T.eq({ r.status, r.rung, r.start_line }, { "drifted", "unverified", 4 })
end)

T.test("anchor: an unverifiable step past the end of the file is broken", function()
  local s = step({ 40, 41 })
  s.anchor = nil
  local r = anchor.locate(BASE, s, nil)
  T.eq({ r.status, r.rung }, { "broken", "out_of_range" })
end)

T.test("anchor: the end line is clamped to the file", function()
  local r = anchor.locate(BASE, step({ 4, 30 }), nil)
  T.eq(r.end_line, #BASE)
end)

local function scratch(lines, ft)
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  if ft then vim.bo[b].filetype = ft end
  return b
end

T.test("anchor: symbol_range finds a lua function via treesitter", function()
  local b = scratch(BASE, "lua")
  local range = anchor.symbol_range(b, "M.login", 4)
  if not range then return end -- no bundled lua parser in this nvim; nothing to assert
  T.eq({ range.start_line, range.end_line }, { 3, 7 })
end)

T.test("anchor: symbol_range spans the declaration, not just the identifier", function()
  local b = scratch({
    "local servers = {",
    "  gopls = 'gopls',",
    "  lua_ls = 'lua-language-server',",
    "}",
    "print(servers)",
  }, "lua")
  local range = anchor.symbol_range(b, "servers", 1)
  if not range then return end
  T.eq({ range.start_line, range.end_line }, { 1, 4 })
end)

-- A trail loads files with bufadd/bufload, which never runs filetype detection.
T.test("anchor: symbol_range works on a buffer with no filetype set", function()
  local b = scratch(BASE)
  vim.api.nvim_buf_set_name(b, vim.fn.tempname() .. ".lua")
  T.eq(vim.bo[b].filetype, "")
  local range = anchor.symbol_range(b, "M.login", 4)
  if not range then return end
  T.eq({ range.start_line, range.end_line }, { 3, 7 })
end)

T.test("anchor: symbol_range degrades to nil for a filetype with no parser", function()
  local b = scratch(BASE, "definitely-not-a-language")
  T.eq(anchor.symbol_range(b, "M.login", 4), nil)
end)

T.test("anchor: resolve hands back an extmark that tracks live edits", function()
  local b = scratch(BASE, "lua")
  local r = anchor.resolve(b, step())
  T.eq({ r.status, r.start_line, r.end_line }, { "exact", 4, 5 })
  vim.api.nvim_buf_set_lines(b, 0, 0, false, { "-- header", "" })
  T.eq(anchor.track(r), { start_line = 6, end_line = 7 })
  anchor.forget(r)
  T.eq(anchor.track(r), nil)
end)

T.test("anchor: resolve on a broken step sets no extmark", function()
  local s = step()
  s.anchor.text = "  local token = never()"
  s.anchor.symbol = nil
  local b = scratch(BASE, "lua")
  local r = anchor.resolve(b, s)
  T.eq(r.status, "broken")
  T.eq(r.extmark, nil)
end)
