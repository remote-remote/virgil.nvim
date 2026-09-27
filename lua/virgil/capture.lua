-- Turns lines in a buffer into a step location: path, range and anchor. The
-- one place an anchor is ever derived, and it reads the buffer, not the file,
-- so unsaved text is what the step anchors to.
local anchor = require("virgil.anchor")
local store = require("virgil.store")

local M = {}

local function is_blank(s)
  return s == nil or not s:find("%S")
end

-- `root` is the trail root; `line1`/`line2` the lines picked, 1-based.
-- Returns { path, range, anchor, bufnr, warnings } or nil and why not.
function M.location(bufnr, line1, line2, root)
  if vim.bo[bufnr].buftype ~= "" then return nil, "not a file buffer" end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil, "the buffer has no file" end
  local file = store.realpath(name) or name
  if file:sub(1, #root + 1) ~= root .. "/" then
    return nil, ("%s is outside the trail root %s"):format(vim.fn.fnamemodify(name, ":~:."), root)
  end

  if line2 < line1 then line1, line2 = line2, line1 end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while line1 <= line2 and is_blank(lines[line1]) do line1 = line1 + 1 end
  while line2 >= line1 and is_blank(lines[line2]) do line2 = line2 - 1 end
  if line1 > line2 then
    return nil, "only blank lines picked; the first line of a step is its anchor"
  end

  local text = lines[line1]
  local found = { text = text }
  local warnings = {}
  if vim.bo[bufnr].modified then
    table.insert(warnings, "the buffer has unsaved changes, so the step anchors to unsaved text")
  end
  local count = 0
  for _, l in ipairs(lines) do
    if l == text then count = count + 1 end
  end
  if count > 1 then
    local symbol = anchor.enclosing_symbol(bufnr, line1)
    if symbol then
      found.symbol = symbol
    else
      table.insert(warnings, ("line %d is not unique in the file and no symbol encloses it, so an edit above it can break the step; start on a more distinctive line"):format(line1))
    end
  end

  return {
    path = file:sub(#root + 2),
    range = { line1, line2 },
    anchor = found,
    bufnr = bufnr,
    warnings = warnings,
  }
end

-- The id rule bin/virgil's `slug` applies to a title.
function M.slug(title)
  local s = title:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  s = s:sub(1, 48):gsub("%-+$", "")
  return s ~= "" and s or "trail"
end

-- A path for a new trail that no file holds yet: the slug, then -2, -3, ...
function M.new_path(dir, title)
  local base = M.slug(title)
  local id, n = base, 1
  while vim.uv.fs_stat(dir .. "/" .. id .. ".json") do
    n = n + 1
    id = ("%s-%d"):format(base, n)
  end
  return dir .. "/" .. id .. ".json", id
end

return M
