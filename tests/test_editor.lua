local plugin = require("virgil")
local editor = require("virgil.editor")
local panel = require("virgil.panel")
local render = require("virgil.render")
local store = require("virgil.store")
local trail = require("virgil.trail")
local S = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/support.lua")

local LINES = {
  "local M = {}",
  "function M.one() return 1 end",
  "function M.two() return 2 end",
  "function M.three() return 3 end",
  "return M",
}

local function on_disk(file)
  return vim.json.decode(S.read(file))
end

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf(), 0, -1, false), "\n")
end

local function note_text(buf)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
    for _, line in ipairs(mark[4].virt_lines or {}) do
      for _, chunk in ipairs(line) do out[#out + 1] = chunk[1] end
    end
  end
  return table.concat(out)
end

-- Opens a.lua in the current tab and starts a trail on line 2 with :VirgilNew.
local function with_new_trail(fn)
  local root = S.repo({ ["a.lua"] = LINES })
  local previous_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = xpcall(function()
    render.setup()
    plugin.setup({ root = root })
    vim.cmd.edit(root .. "/a.lua")
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.cmd("VirgilNew Walk the module")
    T.ok(editor.is_open(), "the editor opened on step 1")
    vim.cmd("stopinsert")
    local file = store.trails_dir(root) .. "/walk-the-module.json"
    fn(root, file)
  end, debug.traceback)
  if editor.is_open() then editor.close() end
  S.cleanup(root)
  if vim.api.nvim_tabpage_is_valid(previous_tab) then vim.api.nvim_set_current_tabpage(previous_tab) end
  if not ok then error(err, 0) end
end

local function type_step(title, note)
  local lines = { title, "" }
  vim.list_extend(lines, vim.split(note, "\n"))
  vim.api.nvim_buf_set_lines(editor.buf(), 0, -1, false, lines)
end

T.test("editor: :VirgilNew writes a one-step trail anchored to the line", function()
  with_new_trail(function(root, file)
    local data = on_disk(file)
    T.eq(data.id, "walk-the-module")
    T.eq(data.root, root)
    T.eq(data.rev, 1)
    T.eq(data.author.kind, "human")
    T.eq(#data.steps, 1)
    T.eq(data.steps[1].range, { 2, 2 })
    T.eq(data.steps[1].anchor, { text = LINES[2] })
    T.eq(data.steps[1].note, "")
    T.eq(vim.api.nvim_buf_get_name(editor.buf()), "virgil://walk-the-module/1")
    T.ok(panel_text():match("stub"), "the new step is a stub")
  end)
end)

T.test("editor: :w saves the title and note, and the note previews live", function()
  with_new_trail(function(_, file)
    type_step("One returns one", "It is the base case.\n\nNothing calls it yet.")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = editor.buf() })
    local code_buf = vim.fn.bufnr(vim.fs.basename("a.lua"))
    T.ok(note_text(code_buf):match("It is the base case"), "live preview: " .. note_text(code_buf))
    T.ok(panel_text():match("One returns one"), "the panel previews the title")
    T.eq(on_disk(file).rev, 1, "a preview writes nothing")

    vim.cmd("write")
    local data = on_disk(file)
    T.eq(data.rev, 2)
    T.eq(data.steps[1].title, "One returns one")
    T.eq(data.steps[1].note, "It is the base case.\n\nNothing calls it yet.")
    T.eq(data.steps[1].anchor, { text = LINES[2] }, "the anchor is untouched")
    T.eq(vim.bo[editor.buf()].modified, false)
    T.ok(not panel_text():match("stub"), "no longer a stub")
  end)
end)

T.test("editor: :VirgilAdd inserts after the current step and :VirgilAdd! pins a stub", function()
  with_new_trail(function(root, file)
    type_step("One", "First.")
    vim.cmd("write")
    editor.close()

    vim.cmd.edit(root .. "/a.lua")
    vim.cmd("4VirgilAdd!")
    T.ok(not editor.is_open(), "a quick pin opens no editor")
    T.eq(trail.index(), 1)

    -- Back on step 1, a new step lands between 1 and the pin.
    plugin.jump(0)
    vim.cmd.edit(root .. "/a.lua")
    vim.cmd("3,4VirgilAdd")
    T.ok(editor.is_open())
    T.eq(trail.index(), 1)
    local data = on_disk(file)
    T.eq(vim.tbl_map(function(s) return s.range end, data.steps), { { 2, 2 }, { 3, 4 }, { 4, 4 } })
    T.eq(data.steps[1].title, "One", "earlier steps are kept")
    T.eq(data.rev, 4)
    T.eq(data.cursor, 1)
  end)
end)

T.test("editor: steps are added after the current one, anchors on others untouched", function()
  with_new_trail(function(root, file)
    editor.close()
    -- A second step whose anchor is stale: only a re-capture may change it.
    local data = on_disk(file)
    table.insert(data.steps, { path = "a.lua", title = "Stale", range = { 4, 4 }, anchor = { text = "gone" }, note = "n" })
    data.rev = 2
    S.write(file, store.encode(data))
    T.ok(vim.wait(2000, function() return trail.count() == 2 end), "reloaded")

    vim.cmd.edit(root .. "/a.lua")
    vim.cmd("5VirgilAdd!")
    data = on_disk(file)
    T.eq(#data.steps, 3)
    T.eq(data.steps[2].range, { 5, 5 })
    T.eq(data.steps[3].anchor, { text = "gone" })
    T.eq(data.steps[3].range, { 4, 4 })
  end)
end)

T.test("editor: :w applies after an agent rewrite that left the step alone", function()
  with_new_trail(function(root, file)
    type_step("One", "First.")
    vim.cmd("write")
    -- An agent prepends a step; the edited step is unchanged but moved.
    local draft = vim.json.encode({ id = "walk-the-module", title = "Walk the module", steps = {
      { path = "a.lua", range = { 5, 5 }, title = "Export", note = "M leaves here." },
      { path = "a.lua", range = { 2, 2 }, title = "One", note = "First." },
    } })
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "2" }, draft)
    T.eq(code, 0, stderr)
    T.ok(vim.wait(2000, function() return trail.count() == 2 end), "reloaded")

    type_step("One, edited", "First, edited.")
    vim.cmd("write")
    local data = on_disk(file)
    T.eq(data.steps[1].title, "Export", "the agent's step is kept")
    T.eq(data.steps[2].title, "One, edited")
    T.eq(data.steps[2].note, "First, edited.")
    T.eq(data.rev, 4)
  end)
end)

T.test("editor: :w refuses when the step changed on disk, :w! overwrites it", function()
  with_new_trail(function(root, file)
    type_step("Mine", "My note.")
    vim.cmd("write")
    local draft = vim.json.encode({ id = "walk-the-module", title = "Walk the module", steps = {
      { path = "a.lua", range = { 2, 2 }, title = "Theirs", note = "Their note." },
    } })
    T.eq((S.cli(root, { "create", "--root", root, "--expect-rev", "2" }, draft)), 0)
    T.ok(vim.wait(2000, function() return trail.current().title == "Theirs" end), "reloaded")

    type_step("Mine again", "My second note.")
    vim.cmd("write")
    T.eq(on_disk(file).steps[1].title, "Theirs", "refused")
    T.eq(vim.bo[editor.buf()].modified, true, "the text is kept")

    vim.cmd("write!")
    local data = on_disk(file)
    T.eq(data.steps[1].title, "Mine again")
    T.eq(data.rev, 4)
  end)
end)

T.test("editor: opening another step while one is open edits the new one", function()
  with_new_trail(function(_, file)
    type_step("One", "First.")
    vim.cmd("write")
    vim.api.nvim_set_current_win(require("virgil.view").code_win())
    vim.cmd("4VirgilAdd")
    T.ok(editor.is_open())
    vim.cmd("stopinsert")
    type_step("Three", "Third.")
    vim.cmd("write")
    local data = on_disk(file)
    T.eq(vim.tbl_map(function(s) return s.title end, data.steps), { "One", "Three" })
    T.eq(vim.bo[editor.buf()].modified, false)
  end)
end)

T.test("editor: :w applies after an agent rewrite that only moved the step", function()
  with_new_trail(function(root, file)
    type_step("One", "First.")
    vim.cmd("write")
    local code_buf = vim.fn.bufnr(vim.fs.basename("a.lua"))
    vim.api.nvim_buf_set_lines(code_buf, 0, 0, false, { "-- inserted" })
    vim.api.nvim_buf_call(code_buf, function() vim.cmd("silent write") end)
    local draft = vim.json.encode({ id = "walk-the-module", title = "Walk the module", steps = {
      { path = "a.lua", range = { 2, 2 }, anchor = { text = LINES[2] }, title = "One", note = "First." },
    } })
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "2" }, draft)
    T.eq(code, 0, stderr)
    T.ok(vim.wait(2000, function() return trail.data().rev == 3 end), "reloaded")
    T.eq(trail.current().range, { 3, 3 }, "the agent moved the step")

    type_step("One, edited", "First, edited.")
    vim.cmd("write")
    local data = on_disk(file)
    T.eq(data.steps[1].title, "One, edited")
    T.eq(data.steps[1].range, { 3, 3 })
    T.eq(data.rev, 4)
  end)
end)

T.test("editor: :VirgilNew with unsaved editor text creates no trail", function()
  with_new_trail(function(root)
    type_step("Unsaved", "Not written yet.")
    T.eq(vim.bo[editor.buf()].modified, true)
    vim.api.nvim_set_current_win(require("virgil.view").code_win())
    vim.cmd("VirgilNew Other trail")
    T.eq(vim.uv.fs_stat(store.trails_dir(root) .. "/other-trail.json"), nil)
    T.eq(trail.data().id, "walk-the-module")
  end)
end)

T.test("editor: a replacing editor does not show the previous step's preview", function()
  with_new_trail(function()
    type_step("One", "First step note.")
    vim.api.nvim_exec_autocmds("TextChanged", { buffer = editor.buf() })
    vim.cmd("write")
    vim.api.nvim_set_current_win(require("virgil.view").code_win())
    vim.cmd("4VirgilAdd")
    vim.cmd("stopinsert")
    vim.cmd("write")
    plugin.show({ keep_cursor = true, preview = true })
    local code_buf = vim.fn.bufnr(vim.fs.basename("a.lua"))
    T.eq(trail.index(), 1)
    T.ok(not note_text(code_buf):match("First step note"), "stale preview: " .. note_text(code_buf))
  end)
end)
