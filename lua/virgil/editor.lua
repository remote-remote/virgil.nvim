-- The step editor: a floating acwrite buffer holding one step's title (line 1)
-- and note (from line 3). `:w` hands the text to `on_write`; the buffer gives
-- the modified flag, undo and `:q!` for free. Knows nothing about trail files.
local M = {}

local ns = vim.api.nvim_create_namespace("virgil-editor")
local FOOTER = " :w save · q close · line 1 is the title "
local STALE_FOOTER = " trail changed on disk · :w saves if this step is unchanged · :w! overwrites it "

-- One editor at a time. `opts` is what `open` was given.
local state = { buf = nil, win = nil, opts = nil }

function M.is_open()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

function M.buf()
  return M.is_open() and state.buf or nil
end

function M.is_modified()
  return M.is_open() and vim.bo[state.buf].modified
end

-- Title and note as the buffer holds them. Line 2 is meant to stay blank, but
-- text typed there belongs to the note rather than being dropped.
function M.parse(lines)
  local title = vim.trim(lines[1] or "")
  local body = {}
  for i = 2, #lines do table.insert(body, lines[i]) end
  local note = table.concat(body, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  return title, note
end

local function contents()
  return M.parse(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false))
end

local function draw_counter()
  if not M.is_open() then return end
  vim.api.nvim_buf_clear_namespace(state.buf, ns, 0, 1)
  local title = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)[1] or ""
  local used = vim.fn.strdisplaywidth(vim.trim(title))
  local budget = state.opts.title_budget
  vim.api.nvim_buf_set_extmark(state.buf, ns, 0, 0, {
    virt_text = { { ("%d/%d"):format(used, budget), used > budget and "VirgilNoteDrifted" or "VirgilMeta" } },
    virt_text_pos = "right_align",
  })
end

local function set_footer(text)
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_set_config, state.win, { footer = text, footer_pos = "center" })
  end
end

function M.close()
  local win, buf = state.win, state.buf
  local on_close = state.opts and state.opts.on_close
  state.buf, state.win, state.opts = nil, nil, nil
  if win and vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
  if buf and vim.api.nvim_buf_is_valid(buf) then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  if on_close then on_close() end
end

-- Returns whether the text was saved. `on_write` reports its own failures.
function M.write(force)
  if not M.is_open() then return false end
  local title, note = contents()
  if not state.opts.on_write(title, note, force) then return false end
  vim.bo[state.buf].modified = false
  set_footer(FOOTER)
  return true
end

-- Tells an open editor its trail was rewritten by someone else.
function M.mark_stale()
  if M.is_open() then set_footer(STALE_FOOTER) end
end

local function ask_close()
  if not M.is_modified() then return M.close() end
  local choice = vim.fn.confirm("Save this step before closing?", "&Yes\n&No\n&Cancel", 1)
  if choice == 1 then
    if M.write(false) then M.close() end
  elseif choice == 2 then
    M.close()
  end
end

local function layout(anchor_win, height)
  local target = anchor_win and vim.api.nvim_win_is_valid(anchor_win) and anchor_win or 0
  local w = vim.api.nvim_win_get_width(target)
  local h = vim.api.nvim_win_get_height(target)
  height = math.max(4, math.min(height, math.floor(h / 2)))
  return {
    relative = "win",
    win = vim.api.nvim_win_is_valid(target) and target or vim.api.nvim_get_current_win(),
    width = math.max(20, w - 4),
    height = height,
    row = math.max(h - height - 3, 0),
    col = 1,
  }
end

-- opts:
--   name         buffer name
--   heading      float title
--   title, note  the text to start from
--   title_budget columns the panel gives a title
--   win          window to float over (the code window)
--   on_write(title, note, force) -> whether it saved
--   on_change(title, note)        live preview
--   on_close()
function M.open(opts)
  if M.is_open() then M.close() end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  local lines = { opts.title or "", "" }
  if opts.note and opts.note ~= "" then vim.list_extend(lines, vim.split(opts.note, "\n", { plain = true })) end
  -- Loaded with undo off, so `u` can never empty the buffer past its opening text.
  local levels = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = -1
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].undolevels = levels
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modified = false

  local config = layout(opts.win, #lines + 3)
  config.style = "minimal"
  config.border = "rounded"
  config.title = " " .. opts.heading .. " "
  config.title_pos = "left"
  config.footer = FOOTER
  config.footer_pos = "center"
  local win = vim.api.nvim_open_win(buf, true, config)
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  state.buf, state.win, state.opts = buf, win, opts

  local group = vim.api.nvim_create_augroup("VirgilEditor", { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = group,
    buffer = buf,
    callback = function() M.write(vim.v.cmdbang == 1) end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = buf,
    callback = function()
      draw_counter()
      if state.opts and state.opts.on_change then state.opts.on_change(contents()) end
    end,
  })
  vim.api.nvim_create_autocmd({ "BufWipeout" }, {
    group = group,
    buffer = buf,
    callback = function()
      if state.buf == buf then
        local on_close = state.opts and state.opts.on_close
        state.buf, state.win, state.opts = nil, nil, nil
        if on_close then vim.schedule(on_close) end
      end
    end,
  })

  local function map(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end
  map("q", ask_close, "Step editor: close")
  map("ZZ", function()
    if not M.is_modified() or M.write(false) then M.close() end
  end, "Step editor: save and close")

  draw_counter()
  vim.api.nvim_win_set_cursor(win, { 1, #(opts.title or "") })
  return buf
end

return M
