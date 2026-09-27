local plugin = require("virgil")
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
  "function M.four() return 4 end",
  "return M",
}

local function keys(input)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), "xt", false)
end

local function on_disk(file)
  return vim.json.decode(S.read(file))
end

local function titles(file)
  return vim.tbl_map(function(s) return s.title end, on_disk(file).steps)
end

local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(panel.buf(), 0, -1, false), "\n")
end

-- Puts the panel cursor on step `index` (0-based) without changing the step.
local function cursor_on(panel_win, index)
  for row = 1, vim.api.nvim_buf_line_count(panel.buf()) do
    if panel.step_at(row) == index then
      vim.api.nvim_win_set_cursor(panel_win, { row, 0 })
      return
    end
  end
  error("no row for step " .. index)
end

-- A trail over a.lua lines 2, 3 and 4, titled One, Two, Three, with the
-- panel focused.
local function with_trail(fn)
  local root = S.repo({ ["a.lua"] = LINES })
  local previous_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = xpcall(function()
    render.setup()
    plugin.setup({ root = root })
    local steps = {}
    for i, name in ipairs({ "One", "Two", "Three" }) do
      steps[i] = { path = "a.lua", title = name, range = { i + 1, i + 1 }, anchor = { text = LINES[i + 1] }, note = name .. "." }
    end
    local file = store.trails_dir(root) .. "/verbs.json"
    plugin.start(assert(store.create(file, { id = "verbs", title = "Verbs", root = root, steps = steps })))
    local panel_win = vim.api.nvim_get_current_win()
    T.eq(vim.bo.filetype, panel.FILETYPE)
    fn(file, panel_win, root)
  end, debug.traceback)
  S.cleanup(root)
  if vim.api.nvim_tabpage_is_valid(previous_tab) then vim.api.nvim_set_current_tabpage(previous_tab) end
  if not ok then error(err, 0) end
end

T.test("panel edit: dd holds a step, p and P put it back with its anchor", function()
  with_trail(function(file, panel_win)
    local original = on_disk(file).steps[1]
    cursor_on(panel_win, 0)
    keys("dd")
    T.eq(titles(file), { "Two", "Three" })
    cursor_on(panel_win, 1)
    keys("p")
    T.eq(titles(file), { "Two", "Three", "One" })
    T.eq(on_disk(file).steps[3], original, "moved without re-deriving its anchor")
    T.eq(trail.index(), 2, "the put step is current")
    cursor_on(panel_win, 0)
    keys("P")
    T.eq(titles(file), { "One", "Two", "Three", "One" })
  end)
end)

T.test("panel edit: dd refuses to empty the trail", function()
  with_trail(function(file, panel_win)
    keys("dd")
    keys("dd")
    T.eq(titles(file), { "Three" })
    cursor_on(panel_win, 0)
    keys("dd")
    T.eq(titles(file), { "Three" })
  end)
end)

T.test("panel edit: J and K move a step and the cursor follows it", function()
  with_trail(function(file, panel_win)
    cursor_on(panel_win, 0)
    keys("J")
    T.eq(titles(file), { "Two", "One", "Three" })
    T.eq(trail.index(), 1)
    T.eq(panel.step_at(vim.api.nvim_win_get_cursor(panel_win)[1]), 1)
    keys("K")
    T.eq(titles(file), { "One", "Two", "Three" })
    cursor_on(panel_win, 0)
    keys("5J")
    T.eq(titles(file), { "Two", "Three", "One" })
  end)
end)

T.test("panel edit: u and <C-r> walk through edits, an outside write clears them", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    keys("J")
    keys("dd")
    T.eq(titles(file), { "Two", "Three" })
    keys("u")
    T.eq(titles(file), { "Two", "One", "Three" })
    keys("u")
    T.eq(titles(file), { "One", "Two", "Three" })
    keys("<C-r>")
    T.eq(titles(file), { "Two", "One", "Three" })
    T.eq(on_disk(file).rev, 6, "each undo and redo is a content write")

    local draft = vim.json.encode({ id = "verbs", title = "Verbs", steps = {
      { path = "a.lua", range = { 5, 5 }, title = "Four", note = "Four." },
    } })
    T.eq((S.cli(root, { "create", "--root", root, "--expect-rev", "6" }, draft)), 0)
    T.ok(vim.wait(2000, function() return trail.count() == 1 end), "reloaded")
    keys("u")
    T.eq(titles(file), { "Four" }, "nothing to undo after an outside write")
  end)
end)

T.test("panel edit: r retitles a step, and the trail on the header", function()
  with_trail(function(file, panel_win)
    local answer
    S.stub(vim.ui, "input", function(_, cb) cb(answer) end, function()
      answer = "  Uno  "
      cursor_on(panel_win, 0)
      keys("r")
      T.eq(titles(file), { "Uno", "Two", "Three" })
      answer = "Renamed trail"
      vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })
      keys("r")
      local data = on_disk(file)
      T.eq({ data.title, data.id }, { "Renamed trail", "verbs" })
      T.ok(file:match("verbs%.json$"))
      T.ok(panel_text():match("Renamed trail"))
      vim.cmd("VirgilRename Again")
      T.eq(on_disk(file).title, "Again")
    end)
  end)
end)

T.test("panel edit: a picks lines in the code window for a new step", function()
  with_trail(function(file, panel_win)
    cursor_on(panel_win, 0)
    keys("a")
    local code_win = vim.api.nvim_get_current_win()
    T.ok(code_win ~= panel_win, "focus moved to the code window")
    T.ok(vim.wo[code_win].winbar:match("after 1"), vim.wo[code_win].winbar)
    vim.api.nvim_win_set_cursor(code_win, { 5, 0 })
    keys("V<CR>")
    local data = on_disk(file)
    T.eq(#data.steps, 4)
    T.eq(data.steps[2].range, { 5, 5 })
    T.eq(data.steps[2].anchor, { text = LINES[5] })
    T.eq(vim.wo[code_win].winbar, "", "the winbar is restored")
    require("virgil.editor").close()

    vim.api.nvim_set_current_win(panel_win)
    keys("A")
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    keys("<Esc>")
    T.eq(#on_disk(file).steps, 4, "Esc cancels")
    T.eq(vim.fn.maparg("<CR>", "n", false, true).desc, nil, "pick maps are gone")
  end)
end)

T.test("panel edit: R preselects the step's lines and re-anchors on the new ones", function()
  with_trail(function(file, panel_win)
    cursor_on(panel_win, 1)
    keys("R")
    T.eq(vim.fn.mode(), "V")
    T.eq({ vim.fn.line("v"), vim.fn.line(".") }, { 3, 3 })
    keys("k<CR>")
    local step = on_disk(file).steps[2]
    T.eq(step.range, { 2, 3 })
    T.eq(step.anchor, { text = LINES[2] })
    T.eq(step.title, "Two", "the text stays")
    T.eq(vim.api.nvim_get_current_win() ~= panel_win, true)
  end)
end)

T.test("panel edit: = takes the place a drifted step was found", function()
  with_trail(function(file, panel_win)
    local code_buf = vim.fn.bufnr(vim.fs.basename("a.lua"))
    vim.api.nvim_buf_set_lines(code_buf, 0, 0, false, { "-- inserted", "-- lines" })
    vim.api.nvim_buf_call(code_buf, function() vim.cmd("silent write") end)
    plugin.start(assert(store.read(file)))
    T.ok(panel_text():match("drift"), "the steps drifted")
    cursor_on(panel_win, 2)
    keys("=")
    local step = on_disk(file).steps[3]
    T.eq(step.range, { 6, 6 })
    T.eq(step.anchor, { text = LINES[4] })
    T.eq(on_disk(file).steps[1].range, { 2, 2 }, "other steps are untouched")
  end)
end)

T.test("panel edit: :VirgilRange moves the current step to the selection", function()
  with_trail(function(file)
    plugin.jump(1)
    require("virgil.view").focus_code()
    vim.cmd("5,6VirgilRange")
    T.eq(on_disk(file).steps[2].range, { 5, 6 })
    T.eq(on_disk(file).steps[2].anchor, { text = LINES[5] })
  end)
end)

T.test("panel edit: an outside write waits for the pick to end", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    keys("a")
    local draft = vim.json.encode({ id = "verbs", title = "Rewritten", steps = {
      { path = "a.lua", range = { 5, 5 }, title = "Four", note = "Four." },
    } })
    T.eq((S.cli(root, { "create", "--root", root, "--expect-rev", "1" }, draft)), 0)
    vim.wait(500)
    T.eq(trail.data().title, "Verbs", "no reload mid-pick")
    keys("<Esc>")
    T.eq(trail.data().title, "Rewritten", "reloaded once the pick ended")
    T.eq(on_disk(file).title, "Rewritten")
  end)
end)

-- The agent's rewrite of the three-step trail: `steps` in place of it.
local function agent_writes(root, rev, steps)
  local draft = vim.json.encode({ id = "verbs", title = "Verbs", steps = steps })
  local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", tostring(rev) }, draft)
  T.eq(code, 0, stderr)
end

local function agent_step(title, line)
  return { path = "a.lua", range = { line, line }, anchor = { text = LINES[line] }, title = title, note = title .. "." }
end

T.test("panel edit: a pick lands on its step after an outside write moved it", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    keys("a")
    agent_writes(root, 1, { agent_step("Zero", 6), agent_step("One", 2), agent_step("Two", 3), agent_step("Three", 4) })
    vim.wait(500)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    keys("<CR>")
    require("virgil.editor").close()
    local data = on_disk(file)
    T.eq(vim.tbl_map(function(s) return s.title end, data.steps), { "Zero", "One", "", "Two", "Three" })
    T.eq(data.steps[3].range, { 5, 5 })
    T.eq(data.rev, 3)

    vim.cmd("stopinsert")
    vim.api.nvim_set_current_win(panel_win)
    cursor_on(panel_win, 3)
    keys("R")
    agent_writes(root, 3, { agent_step("Two", 3), agent_step("One", 2), agent_step("Three", 4) })
    vim.wait(500)
    keys("j<CR>")
    data = on_disk(file)
    T.eq(vim.tbl_map(function(s) return s.title end, data.steps), { "Two", "One", "Three" })
    T.eq(data.steps[1].range, { 3, 4 }, "the re-range followed step Two")
  end)
end)

T.test("panel edit: a pick is refused when its step changed or doubled on disk", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    keys("a")
    agent_writes(root, 1, { agent_step("Uno", 2), agent_step("Two", 3), agent_step("Three", 4) })
    vim.wait(500)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    keys("<CR>")
    T.eq(on_disk(file).rev, 2, "nothing was saved")
    T.eq(trail.data().steps[1].title, "Uno", "the outside write was loaded")

    vim.api.nvim_set_current_win(panel_win)
    cursor_on(panel_win, 1)
    keys("a")
    agent_writes(root, 2, { agent_step("Two", 3), agent_step("Uno", 2), agent_step("Two", 3) })
    vim.wait(500)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    keys("<CR>")
    T.eq(on_disk(file).rev, 3, "an ambiguous target saves nothing")
  end)
end)

T.test("panel edit: r refuses when the trail changed while the title was typed", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    S.stub(vim.ui, "input", function(_, cb)
      agent_writes(root, 1, { agent_step("Zero", 6), agent_step("One", 2), agent_step("Two", 3), agent_step("Three", 4) })
      T.ok(vim.wait(2000, function() return trail.count() == 4 end), "reloaded")
      cb("Retitled")
    end, function() keys("r") end)
    local data = on_disk(file)
    T.eq(vim.tbl_map(function(s) return s.title end, data.steps), { "Zero", "One", "Two", "Three" })
    T.eq(data.rev, 2)
  end)
end)

T.test("panel edit: undo history stays with its trail", function()
  with_trail(function(file, panel_win, root)
    cursor_on(panel_win, 0)
    keys("J")
    local other = store.trails_dir(root) .. "/other.json"
    local steps = { { path = "a.lua", title = "Solo", range = { 2, 2 }, anchor = { text = LINES[2] }, note = "Solo." } }
    plugin.start(assert(store.create(other, { id = "other", title = "Other", root = root, steps = steps })))
    keys("u")
    T.eq(titles(other), { "Solo" })
    T.eq(on_disk(other).rev, 1)
    T.eq(titles(file), { "Two", "One", "Three" })
  end)
end)

T.test("panel edit: :VirgilDelete asks, then removes the file and closes the trail", function()
  with_trail(function(file)
    local answer = 2
    S.stub(vim.fn, "confirm", function() return answer end, function()
      vim.cmd("VirgilDelete")
      T.ok(vim.uv.fs_stat(file), "cancel keeps it")
      answer = 1
      vim.cmd("VirgilDelete")
      T.eq(vim.uv.fs_stat(file), nil)
      T.eq(trail.is_active(), false)
    end)
  end)
end)

T.test("panel edit: a trail deleted on disk says so and refuses edits", function()
  with_trail(function(file, panel_win)
    os.remove(file)
    T.ok(vim.wait(2000, function() return panel_text():match("deleted on disk") ~= nil end), panel_text())
    cursor_on(panel_win, 0)
    keys("J")
    T.eq(vim.uv.fs_stat(file), nil, "nothing was written")
  end)
end)

T.test("panel edit: g? lists the panel's keys", function()
  with_trail(function()
    local echoed
    S.stub(vim.api, "nvim_echo", function(...) echoed = (...) end, function() keys("g?") end)
    local text = table.concat(vim.tbl_map(function(c) return c[1] end, echoed))
    for _, k in ipairs({ "dd", "e ", "R ", "= ", "J ", "u ", "g?" }) do
      T.ok(text:find(k, 1, true), "lists " .. k .. "\n" .. text)
    end
  end)
end)
