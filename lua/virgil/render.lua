-- Code-side decoration: the highlighted range, its signs, and the narration as
-- virtual lines. Replaceable when taste changes.
local format = require("virgil.format")

local M = {}

M.ns = vim.api.nvim_create_namespace("virgil-render")

local GUTTER = "▌"

local HIGHLIGHTS = {
  VirgilNote = "DiagnosticInfo",
  VirgilNoteDrifted = "DiagnosticWarn",
  VirgilNoteBroken = "DiagnosticError",
  VirgilRange = "Visual",
  VirgilRangeDrifted = "DiffChange",
  VirgilRangeBroken = "DiffDelete",
  VirgilMeta = "Comment",
  VirgilPanelTitle = "Title",
  VirgilPanelCount = "Special",
  VirgilPanelIndex = "LineNr",
  VirgilPanelStep = "Normal",
  VirgilPanelCurrent = "Title",
  VirgilPanelMarker = "Special",
  VirgilPanelPath = "Comment",
}

local STYLE = {
  exact = { note = "VirgilNote", range = "VirgilRange", sign = "▎" },
  drifted = { note = "VirgilNoteDrifted", range = "VirgilRangeDrifted", sign = "▎" },
  broken = { note = "VirgilNoteBroken", range = "VirgilRangeBroken", sign = "▎" },
}

local active = { bufnr = nil, start_line = nil }

function M.apply_highlights()
  for name, link in pairs(HIGHLIGHTS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

function M.setup()
  M.apply_highlights()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("VirgilHighlights", { clear = true }),
    callback = M.apply_highlights,
  })
end

local function narration(view, width)
  local style = STYLE[view.status] or STYLE.exact
  local indent = (view.indent or ""):gsub("\t", "  ")
  local body = math.max(width - #indent - 4, 30)
  local chunks = {}

  local function push(text, hl)
    table.insert(chunks, { { indent .. GUTTER .. " ", style.note }, { text, hl } })
  end

  if (view.note or ""):find("%S") then
    for _, line in ipairs(format.wrap(view.note, body)) do
      push(line, style.note)
    end
  else
    push("no note yet", "VirgilMeta")
  end
  if view.detail then
    push("", "VirgilMeta")
    push(view.detail, "VirgilMeta")
  end
  return chunks
end

-- Virtual lines above row 0 sit outside the viewport and never draw: nvim only
-- shows them once w_topfill is set, which a fresh jump never does. With no room
-- above, hang the narration under the range rather than over it.
function M.note_anchor(start_line, end_line)
  if start_line > 1 then return start_line - 1, true end
  return end_line - 1, false
end

function M.clear()
  if active.bufnr and vim.api.nvim_buf_is_valid(active.bufnr) then
    vim.api.nvim_buf_clear_namespace(active.bufnr, M.ns, 0, -1)
  end
  active = { bufnr = nil, start_line = nil }
end

function M.show(win, view)
  local was = { bufnr = active.bufnr, start_line = active.start_line }
  M.clear()

  local bufnr = vim.fn.bufadd(view.file)
  vim.fn.bufload(bufnr)
  vim.bo[bufnr].buflisted = true
  -- bufload skips filetype detection, so a file the reader has never opened
  -- arrives with no filetype and therefore no treesitter highlighting.
  if vim.bo[bufnr].filetype == "" then
    vim.api.nvim_buf_call(bufnr, function() vim.cmd("filetype detect") end)
  end
  -- Consecutive steps in the same file keep the buffer, and with it the window's
  -- view, its folds and its jumplist.
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    vim.api.nvim_win_set_buf(win, bufnr)
  end

  local count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.min(math.max(view.start_line or 1, 1), count)
  local end_line = math.min(math.max(view.end_line or start_line, start_line), count)
  local first = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1] or ""
  local last = vim.api.nvim_buf_get_lines(bufnr, end_line - 1, end_line, false)[1] or ""
  view.indent = first:match("^%s*") or ""

  local style = STYLE[view.status] or STYLE.exact
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, start_line - 1, 0, {
    end_row = end_line - 1,
    end_col = #last,
    hl_group = style.range,
    hl_eol = true,
    sign_text = style.sign,
    sign_hl_group = style.note,
    priority = 120,
  })
  local note_row, above = M.note_anchor(start_line, end_line)
  -- textoff, not the window width: number and sign columns are not text area,
  -- and narration wrapped to the full width runs off the right edge.
  local info = vim.fn.getwininfo(win)[1]
  local text_width = vim.api.nvim_win_get_width(win) - ((info and info.textoff) or 0)
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, note_row, 0, {
    virt_lines = narration(view, text_width),
    virt_lines_above = above,
    priority = 120,
  })
  for line = start_line, end_line - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, M.ns, line, 0, {
      sign_text = style.sign,
      sign_hl_group = style.note,
      priority = 120,
    })
  end

  -- Only move when the step actually moved. A redraw triggered by the watcher or
  -- by an edit must not throw away where the reader had scrolled to.
  if was.bufnr ~= bufnr or was.start_line ~= start_line then
    vim.api.nvim_win_set_cursor(win, { start_line, 0 })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
  end

  active = { bufnr = bufnr, start_line = start_line }
  return bufnr
end

return M
