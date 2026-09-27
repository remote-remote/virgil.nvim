-- Pick mode: the reader chooses lines in the code window, with the cursor or a
-- visual selection, and confirms with <CR> or cancels with <Esc>. The maps
-- follow the window rather than a buffer, since the reader may open another
-- file to pick from, and whatever buffer-local maps they replace come back.
local M = {}

local KEYS = { { "n", "<CR>" }, { "x", "<CR>" }, { "n", "<Esc>" }, { "x", "<Esc>" } }
local group = vim.api.nvim_create_augroup("VirgilPick", { clear = true })

-- { win, winbar, saved = { [buf] = { maparg... } }, on_done, on_end }
local state = nil

function M.active()
  return state ~= nil
end

local function unmap(buf, saved)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for i, key in ipairs(KEYS) do
    pcall(vim.keymap.del, key[1], key[2], { buffer = buf })
    local prev = saved[i]
    if prev and next(prev) and prev.buffer == 1 then
      vim.api.nvim_buf_call(buf, function() vim.fn.mapset(key[1], false, prev) end)
    end
  end
end

local function finish(lines)
  local s = state
  if not s then return end
  state = nil
  vim.api.nvim_clear_autocmds({ group = group })
  for buf, saved in pairs(s.saved) do unmap(buf, saved) end
  if vim.api.nvim_win_is_valid(s.win) then vim.wo[s.win].winbar = s.winbar end
  if lines then s.on_done(lines.bufnr, lines.line1, lines.line2) end
  if s.on_end then s.on_end() end
end

local function leave_visual()
  if vim.fn.mode():match("^[vV\22]") then
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  end
end

local function map(buf)
  if not state or state.saved[buf] then return end
  local saved = {}
  for i, key in ipairs(KEYS) do
    saved[i] = vim.api.nvim_buf_call(buf, function() return vim.fn.maparg(key[2], key[1], false, true) end)
  end
  state.saved[buf] = saved
  local opts = { buffer = buf, nowait = true, silent = true }
  local function confirm()
    local line1, line2 = vim.fn.line("v"), vim.fn.line(".")
    leave_visual()
    finish({ bufnr = vim.api.nvim_get_current_buf(), line1 = math.min(line1, line2), line2 = math.max(line1, line2) })
  end
  local function cancel()
    leave_visual()
    finish(nil)
  end
  vim.keymap.set({ "n", "x" }, "<CR>", confirm, vim.tbl_extend("force", opts, { desc = "Trail: use these lines" }))
  vim.keymap.set({ "n", "x" }, "<Esc>", cancel, vim.tbl_extend("force", opts, { desc = "Trail: cancel" }))
end

-- opts.message   what the winbar says while picking
-- opts.select    { start_line, end_line } to preselect, linewise
-- opts.on_done(bufnr, line1, line2)
-- opts.on_end()  after either outcome
function M.start(win, opts)
  if state then finish(nil) end
  state = { win = win, winbar = vim.wo[win].winbar, saved = {}, on_done = opts.on_done, on_end = opts.on_end }
  vim.wo[win].winbar = "%#VirgilPanelMarker# virgil: %*" .. opts.message:gsub("%%", "%%%%")
    .. " · <CR> use · <Esc> cancel"
  vim.api.nvim_set_current_win(win)
  map(vim.api.nvim_win_get_buf(win))
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      if state and vim.api.nvim_get_current_win() == state.win then map(vim.api.nvim_get_current_buf()) end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    callback = function() vim.schedule(M.cancel) end,
  })
  if opts.select then
    local s, e = opts.select[1], opts.select[2]
    vim.api.nvim_win_set_cursor(win, { s, 0 })
    vim.cmd("normal! V")
    vim.api.nvim_win_set_cursor(win, { e, 0 })
  end
end

function M.cancel()
  finish(nil)
end

return M
