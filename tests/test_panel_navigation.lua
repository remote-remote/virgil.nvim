local plugin = require("virgil")
local panel = require("virgil.panel")
local render = require("virgil.render")
local store = require("virgil.store")
local trail = require("virgil.trail")

local function keys(input)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input, true, false, true), "xt", false)
end

local function with_trail(opts, fn)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = store.realpath(root)
  vim.fn.mkdir(store.trails_dir(root), "p")
  local lines = { "-- header", "local first = 1", "", "local second = 2", "", "return first + second" }
  for _, name in ipairs({ "a.lua", "b.lua" }) do
    vim.fn.writefile(lines, root .. "/" .. name)
  end
  local steps = {}
  for i, location in ipairs({ { "a.lua", 2 }, { "a.lua", 4 }, { "b.lua", 2 } }) do
    steps[i] = {
      path = location[1], range = { location[2], location[2] },
      anchor = { text = lines[location[2]] },
      title = "Step " .. i, note = "Note for step " .. i,
    }
  end
  if opts.single then steps = { steps[1] } end
  local file = store.trails_dir(root) .. "/navigation.json"
  vim.fn.writefile({ vim.json.encode({
    version = 1, id = "navigation", root = root,
    title = "A long trail title that wraps across multiple lines in the index panel",
    cursor = opts.cursor or 0, steps = steps,
  }) }, file)
  local previous_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = xpcall(function()
    render.setup()
    plugin.start(assert(store.read(file)))
    local panel_win = vim.api.nvim_get_current_win()
    T.eq(vim.bo.filetype, panel.FILETYPE)
    local code_win
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if win ~= panel_win then code_win = win end
    end
    T.ok(code_win, "trail has a code window")

    local function expect(index, focused)
      local step = steps[index + 1]
      T.eq(trail.index(), index)
      T.eq(vim.api.nvim_get_current_win(), focused == "code" and code_win or panel_win)
      local row = vim.api.nvim_win_get_cursor(panel_win)[1]
      T.eq(panel.step_at(row), index)
      T.ok(panel.step_at(row - 1) ~= index, "cursor is on the title, not path:line")
      local buf = vim.api.nvim_win_get_buf(code_win)
      T.eq(vim.api.nvim_buf_get_name(buf), root .. "/" .. step.path)
      T.eq(vim.api.nvim_win_get_cursor(code_win)[1], step.range[1])
      local notes = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, render.ns, 0, -1, { details = true })) do
        for _, line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(line) do notes[#notes + 1] = chunk[1] end
        end
      end
      T.eq(table.concat(notes), "▌ " .. step.note)
      T.eq(assert(store.read(file)).cursor, index)
    end
    fn(expect, panel_win, code_win)
  end, debug.traceback)
  plugin.quit()
  T.eq(vim.api.nvim_get_current_tabpage(), previous_tab)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
  if not ok then error(err, 0) end
end

T.test("panel: j/k preview whole steps without leaving the index", function()
  with_trail({}, function(expect, _, code_win)
    expect(0)
    keys("j")
    expect(1)
    local old_buf = vim.api.nvim_win_get_buf(code_win)
    keys("j")
    expect(2)
    T.eq(vim.api.nvim_buf_get_extmarks(old_buf, render.ns, 0, -1, {}), {})
    keys("k")
    expect(1)
    keys("k")
    expect(0)
  end)
end)

T.test("panel: counted motions and boundaries stay on step titles", function()
  with_trail({}, function(expect)
    keys("k")
    expect(0)
    keys("2j")
    expect(2)
    keys("j")
    expect(2)
    keys("99k")
    expect(0)
    keys("99j")
    expect(2)
  end)
end)

T.test("panel: Enter focuses the previewed code and leaves code j/k alone", function()
  with_trail({}, function(expect, _, code_win)
    keys("j")
    expect(1)
    keys("<CR>")
    expect(1, "code")
    keys("j")
    T.eq(vim.api.nvim_win_get_cursor(code_win)[1], 5)
    T.eq(trail.index(), 1)
    keys("k")
    expect(1, "code")
  end)
end)

T.test("panel: navigation starts from the restored step", function()
  with_trail({ cursor = 1 }, function(expect)
    expect(1)
    keys("k")
    expect(0)
  end)
end)

T.test("panel: motions use the entry under the cursor, or the active step in the header", function()
  with_trail({}, function(expect, panel_win)
    local first_row = vim.api.nvim_win_get_cursor(panel_win)[1]
    vim.api.nvim_win_set_cursor(panel_win, { first_row + 5, 0 })
    keys("k")
    expect(1)
    vim.api.nvim_win_set_cursor(panel_win, { 1, 0 })
    keys("k")
    expect(0)
  end)
end)

T.test("panel: a single-step trail stays selected until Enter focuses code", function()
  with_trail({ single = true }, function(expect)
    keys("jk99j99k")
    expect(0)
    keys("<CR>")
    expect(0, "code")
  end)
end)
