-- The trail's tabpage: a fixed-width panel on the left, the code on the right.
-- Owns window lifecycle and teardown. Drawing lives in `panel` and `render`.
local panel = require("virgil.panel")
local render = require("virgil.render")

local M = {}

-- Fired when the tabpage or either of its windows goes away, so the rest of the
-- plugin can drop its anchors. Set by init.
M.on_close = function() end

local state = { tabpage = nil, panel_win = nil, code_win = nil, closing = false }
local group = vim.api.nvim_create_augroup("VirgilView", { clear = true })

local function win_alive(win, wins)
  return win ~= nil and vim.tbl_contains(wins, win)
end

function M.is_open()
  return state.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(state.tabpage)
end

function M.is_current()
  return M.is_open() and vim.api.nvim_get_current_tabpage() == state.tabpage
end

-- WinClosed fires before the window is gone and TabClosed hands back a tab
-- number rather than a handle, so both callbacks decide from the layout instead
-- of the event payload.
local function watch()
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd("TabClosed", {
    group = group,
    callback = function()
      if state.tabpage and not vim.api.nvim_tabpage_is_valid(state.tabpage) then M.close() end
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
      local win = tonumber(args.match)
      if win and (win == state.panel_win or win == state.code_win) then
        vim.schedule(M.close)
      end
    end,
  })
end

local function open_tab()
  -- `tab split` keeps a real buffer in the new window; nvim refuses it from some
  -- floats, and then a blank tab will do.
  if not pcall(vim.cmd, "tab split") then vim.cmd("tabnew") end
  state.tabpage = vim.api.nvim_get_current_tabpage()
  state.code_win = vim.api.nvim_get_current_win()
  state.panel_win = nil
  watch()
end

local function ensure_layout()
  if M.is_open() then
    vim.api.nvim_set_current_tabpage(state.tabpage)
  else
    open_tab()
  end

  local wins = vim.api.nvim_tabpage_list_wins(state.tabpage)
  if not win_alive(state.code_win, wins) then
    state.code_win = nil
    for _, win in ipairs(wins) do
      if win ~= state.panel_win then
        state.code_win = win
        break
      end
    end
  end

  if not win_alive(state.panel_win, wins) then
    -- topleft, not a split of the code window: the panel spans the full height
    -- on the far left however many windows the tab has grown.
    vim.cmd("topleft vsplit")
    state.panel_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.panel_win, panel.buf())
    for opt, value in pairs(panel.WINOPTS) do
      vim.wo[state.panel_win][opt] = value
    end
    -- Only on creation. Snapping the width back on every step would undo a
    -- resize the reader just made.
    vim.api.nvim_win_set_width(state.panel_win, panel.WIDTH)
  end

  if not state.code_win then
    vim.api.nvim_win_call(state.panel_win, function()
      vim.cmd("rightbelow vsplit")
      state.code_win = vim.api.nvim_get_current_win()
    end)
  end
end

function M.focus_code()
  if M.is_open() and state.code_win and vim.api.nvim_win_is_valid(state.code_win) then
    vim.api.nvim_set_current_win(state.code_win)
  end
end

function M.show(spec)
  local first = not M.is_open()
  ensure_layout()
  render.show(state.code_win, spec.code)
  panel.draw(state.panel_win, spec.panel, spec.keep_cursor)
  if first then vim.api.nvim_set_current_win(state.panel_win) end
end

function M.close()
  if state.closing then return end
  state.closing = true

  render.clear()
  panel.clear()
  vim.api.nvim_clear_autocmds({ group = group })

  local tab = state.tabpage
  state.tabpage, state.panel_win, state.code_win = nil, nil, nil
  M.on_close()

  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #vim.api.nvim_list_tabpages() == 1 then vim.cmd("tabnew") end
    pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
  end
  state.closing = false
end

return M
