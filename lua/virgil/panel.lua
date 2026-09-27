-- The trail index: a nofile buffer listing every step with its live line and
-- anchor status. Knows nothing about the code window; it draws a spec and maps
-- keys back to the plugin.
local format = require("virgil.format")

local M = {}

M.ns = vim.api.nvim_create_namespace("virgil-panel")
M.FILETYPE = "virgil-panel"
M.WIDTH = 38

M.WINOPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false,
  foldmethod = "manual",
  wrap = false,
  list = false,
  spell = false,
  cursorline = true,
  winfixwidth = true,
  colorcolumn = "",
  -- The config sets scrolloff=15 globally, which in a 38-column panel would
  -- scroll the list on every j.
  scrolloff = 0,
  sidescrolloff = 0,
  fillchars = "eob: ",
  statusline = " trail",
  -- A fresh split inherits whatever winbar the window it came from had, and
  -- lspsaga's symbol winbar keeps setting one; the panel is not a code window.
  winbar = "",
}

local state = { bufnr = nil, rows = {}, index = nil }

local function plugin()
  return require("virgil")
end

-- Every panel key with its description, in the order `g?` lists them.
local KEYS = {}

local function map(buf, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  if not vim.tbl_contains(vim.tbl_map(function(k) return k[1] end, KEYS), lhs) then
    table.insert(KEYS, { lhs, (desc:gsub("^Trail: ", "")) })
  end
end

function M.step_at(lnum)
  return state.rows[lnum]
end

local function keymaps(buf)
  local function under_cursor()
    return M.step_at(vim.api.nvim_win_get_cursor(0)[1])
  end
  -- The step a verb acts on: the one under the cursor, or the current step
  -- when the cursor is on the header.
  local function target()
    return under_cursor() or state.index
  end
  local function move(delta)
    local i = under_cursor() or state.index
    if i then plugin().jump(i + delta * vim.v.count1) end
  end
  map(buf, "j", function() move(1) end, "Trail: preview next step")
  map(buf, "k", function() move(-1) end, "Trail: preview previous step")
  map(buf, "<CR>", function()
    local i = under_cursor()
    if i then plugin().select(i) end
  end, "Trail: go to step")
  map(buf, "o", function()
    local i = under_cursor()
    if i then plugin().jump(i) end
  end, "Trail: show step, stay in panel")
  map(buf, "]t", function() plugin().next() end, "Trail: next step")
  map(buf, "[t", function() plugin().prev() end, "Trail: previous step")
  map(buf, "e", function() plugin().edit(target()) end, "Trail: edit this step's title and note")
  map(buf, "r", function()
    local i = under_cursor()
    if i then plugin().retitle(i) else plugin().rename() end
  end, "Trail: retitle this step, or the trail on the header")
  map(buf, "a", function() plugin().pick_add(target()) end, "Trail: add a step after this one")
  map(buf, "A", function() plugin().pick_add(target(), true) end, "Trail: add a step at the end")
  map(buf, "R", function() plugin().pick_range(target()) end, "Trail: re-range this step")
  map(buf, "=", function() plugin().accept_drift(target()) end, "Trail: accept drift, re-anchor where found")
  map(buf, "dd", function() plugin().delete_step(target()) end, "Trail: delete this step and hold it")
  map(buf, "p", function() plugin().put(target(), false) end, "Trail: put the held step after this one")
  map(buf, "P", function() plugin().put(target(), true) end, "Trail: put the held step before this one")
  map(buf, "J", function() plugin().move(target(), vim.v.count1) end, "Trail: move this step down")
  map(buf, "K", function() plugin().move(target(), -vim.v.count1) end, "Trail: move this step up")
  map(buf, "u", function() plugin().undo() end, "Trail: undo the last edit")
  map(buf, "<C-r>", function() plugin().redo() end, "Trail: redo")
  map(buf, "q", function() plugin().quit() end, "Trail: quit")
  map(buf, "Q", function() plugin().to_quickfix() end, "Trail: dump to quickfix")
  map(buf, "g?", function() M.help() end, "Trail: show the panel's keys")
end

function M.help()
  M.buf()
  local chunks = { { "virgil panel keys\n", "Title" } }
  for _, k in ipairs(KEYS) do table.insert(chunks, { ("%-6s %s\n"):format(k[1], k[2]) }) end
  vim.api.nvim_echo(chunks, false, {})
end

function M.buf()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then return state.bufnr end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modeline = false
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = M.FILETYPE
  -- The name is what a tabline shows for this tab, so it says what the tab is
  -- rather than which of its two buffers happens to be focused.
  pcall(vim.api.nvim_buf_set_name, buf, "virgil://trail")
  state.bufnr = buf
  keymaps(buf)
  return buf
end

-- Only recenter when the target has fallen out of view, so a short trail keeps
-- its list pinned to the top instead of floating in the middle of the window.
local function reveal(win, lnum)
  vim.api.nvim_win_call(win, function()
    if lnum < vim.fn.line("w0") or lnum > vim.fn.line("w$") then
      vim.cmd("normal! zz")
    end
  end)
end

-- `keep_cursor` is what the file watcher wants: a redraw that leaves the reader
-- where they were browsing instead of yanking the cursor to the current step.
function M.draw(win, spec, keep_cursor)
  local buf = M.buf()
  local width = vim.api.nvim_win_get_width(win)
  local built = format.panel(spec, width)
  state.rows, state.index = built.rows, spec.index

  local saved
  if keep_cursor and vim.api.nvim_win_get_buf(win) == buf then
    saved = vim.api.nvim_win_get_cursor(win)[1]
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, built.lines)
  vim.bo[buf].modifiable = false

  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, m in ipairs(built.marks) do
    local row, col, end_col, hl = m[1], m[2], m[3], m[4]
    local len = #built.lines[row + 1]
    end_col = math.min(end_col, len)
    if col < end_col then
      pcall(vim.api.nvim_buf_set_extmark, buf, M.ns, row, col, { end_col = end_col, hl_group = hl })
    end
  end

  local target = math.max(1, math.min(saved or built.current_row or 1, #built.lines))
  vim.api.nvim_win_set_cursor(win, { target, 0 })
  reveal(win, target)
end

function M.clear()
  state.rows, state.index = {}, nil
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    vim.bo[state.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
    vim.bo[state.bufnr].modifiable = false
    vim.api.nvim_buf_clear_namespace(state.bufnr, M.ns, 0, -1)
  end
end

return M
