-- Pure display formatting. Strings and widths in, strings and byte-column spans
-- out, so every layout decision the panel makes is testable without a window.
local M = {}

local ELLIPSIS = "…"
local MARKER = "▸"
local BADGE = { drifted = "drift", broken = "broken" }
local BADGE_HL = { drifted = "VirgilNoteDrifted", broken = "VirgilNoteBroken" }

local function cells(s)
  return vim.fn.strdisplaywidth(s)
end

function M.truncate(s, width)
  if width <= 0 then return "" end
  if cells(s) <= width then return s end
  local n = math.min(vim.fn.strchars(s), width)
  while n > 0 do
    local cut = vim.fn.strcharpart(s, 0, n)
    if cells(cut) + 1 <= width then return cut .. ELLIPSIS end
    n = n - 1
  end
  return ELLIPSIS
end

-- Prefers a word boundary, but only one in the back half of the string: cutting
-- "How a login request becomes" down to "How" would be worse than a severed word.
function M.truncate_words(s, width)
  if cells(s) <= width then return s end
  local cut = M.truncate(s, width)
  local body = cut:sub(1, #cut - #ELLIPSIS)
  local space = body:match("^.*()%s")
  if space and space > #body / 2 then
    return body:sub(1, space - 1) .. ELLIPSIS
  end
  return cut
end

function M.wrap(text, width)
  local out = {}
  for paragraph in (text .. "\n"):gmatch("(.-)\n") do
    if paragraph == "" then
      table.insert(out, "")
    else
      local line = ""
      for word in paragraph:gmatch("%S+") do
        if line == "" then
          line = word
        elseif #line + #word + 1 <= width then
          line = line .. " " .. word
        else
          table.insert(out, line)
          line = word
        end
      end
      if line ~= "" then table.insert(out, line) end
    end
  end
  if #out == 0 then out = { "" } end
  return out
end

-- A sentence ends at punctuation followed by whitespace, not at any period.
-- Notes are full of `vim.env.HERDR_ENV` and `lazy.setup()`, and none of those
-- dots have a space after them.
function M.first_sentence(note)
  local flat = (note or ""):gsub("%s+", " ")
  flat = vim.trim(flat)
  if flat == "" then return "" end
  local stop = flat:find("[.!?]%s")
  if not stop and flat:find("[.!?]$") then stop = #flat end
  if not stop then return flat end
  return vim.trim(flat:sub(1, stop - 1))
end

-- The panel is 38 columns, so a step without an authored title has to be given
-- one. Falls all the way back to the filename rather than rendering a blank row.
function M.step_title(step, width)
  local authored = type(step.title) == "string" and vim.trim(step.title) or ""
  if authored ~= "" then return M.truncate(authored, width) end
  local derived = M.first_sentence(step.note)
  if derived ~= "" then return M.truncate_words(derived, width) end
  local base = vim.fs.basename(step.path or "")
  if base ~= "" then return M.truncate(base, width) end
  return "(step)"
end

-- Basename, not the relative path: at 38 columns some paths would fit and most
-- would not, and a column that is sometimes `src/auth.ts` and sometimes
-- `auth.ts` reads as noise. The code window's statusline carries the full path.
-- The line number is never sacrificed; it is the part you retype into a jump.
local function path_label(path, line, width)
  local suffix = ":" .. tostring(line or "?")
  local base = vim.fs.basename(path or "")
  local room = width - #suffix
  if room <= 0 then return M.truncate(base .. suffix, width) end
  if cells(base) <= room then return base .. suffix end
  return M.truncate(base, room) .. suffix
end

-- One entry is two lines: `▸ 3 Token minted` over an indented `path:line` with a
-- right-aligned drift badge. Byte columns come back with it so the panel never
-- has to find the spans again by searching the text.
function M.entry(e, opts)
  local width = opts.width
  local numw = opts.number_width or 1
  local marker = opts.current and MARKER or " "
  local number = ("%" .. numw .. "d"):format(e.index + 1)

  local marker_end = #marker
  local number_col = marker_end + 1
  local number_end = number_col + #number
  local title_col = number_end + 1

  local title = M.step_title(e.step, math.max(width - (numw + 3), 8))
  local top = marker .. " " .. number .. " " .. title

  local indent = (" "):rep(numw + 3)
  local badge = BADGE[e.status]
  local room = width - #indent - (badge and (#badge + 1) or 0)
  local bottom = indent .. path_label(e.step.path or "", e.line, math.max(room, 4))
  local badge_col
  if badge then
    local pad = width - cells(bottom) - #badge
    bottom = bottom .. (" "):rep(math.max(pad, 1))
    badge_col = #bottom
    bottom = bottom .. badge
  end

  return {
    top = M.truncate(top, width),
    bottom = bottom,
    marker_end = marker_end,
    number_col = number_col,
    number_end = number_end,
    title_col = title_col,
    badge_col = badge_col,
    badge_hl = badge and BADGE_HL[e.status] or nil,
  }
end

-- Trail title wrapped to the panel, with `N/M` tucked onto the last line when
-- there is room and given its own line when there is not.
function M.header(title, index, total, width)
  local count = ("%d/%d"):format(index + 1, total)
  local body = math.max(width - 2, #count + 1)
  local lines = M.wrap(title or "trail", body)
  local last = lines[#lines]
  local count_line, count_col

  if cells(last) + #count + 2 <= body then
    lines[#lines] = last .. (" "):rep(body - cells(last) - #count) .. count
    count_line = #lines
  else
    table.insert(lines, (" "):rep(body - #count) .. count)
    count_line = #lines
  end
  count_col = #lines[count_line] - #count

  for i, line in ipairs(lines) do
    lines[i] = " " .. line
  end
  return { lines = lines, count_line = count_line, count_col = count_col + 1 }
end

-- The whole panel body: the lines to write, the highlight spans to lay over
-- them, a line -> step index map for <CR>, and where the cursor should snap.
function M.panel(spec, width)
  local lines, marks, rows = {}, {}, {}
  local current_row

  local function push(text)
    table.insert(lines, text)
    return #lines - 1
  end
  local function mark(row, col, end_col, hl)
    if end_col > col then table.insert(marks, { row, col, end_col, hl }) end
  end

  local head = M.header(spec.title, spec.index, spec.total, width)
  for i, text in ipairs(head.lines) do
    local row = push(text)
    if i == head.count_line then
      mark(row, 0, head.count_col, "VirgilPanelTitle")
      mark(row, head.count_col, #text, "VirgilPanelCount")
    else
      mark(row, 0, #text, "VirgilPanelTitle")
    end
  end
  push("")

  local numw = #tostring(math.max(spec.total, 1))
  for _, e in ipairs(spec.entries) do
    local current = e.index == spec.index
    local ent = M.entry(e, { width = width, number_width = numw, current = current })

    local row = push(ent.top)
    rows[row + 1] = e.index
    if current then
      current_row = row + 1
      mark(row, 0, ent.marker_end, "VirgilPanelMarker")
    end
    mark(row, ent.number_col, ent.number_end, "VirgilPanelIndex")
    mark(row, ent.title_col, #ent.top, current and "VirgilPanelCurrent" or "VirgilPanelStep")

    row = push(ent.bottom)
    rows[row + 1] = e.index
    mark(row, 0, ent.badge_col or #ent.bottom, "VirgilPanelPath")
    if ent.badge_col then mark(row, ent.badge_col, #ent.bottom, ent.badge_hl) end
  end

  return { lines = lines, marks = marks, rows = rows, current_row = current_row }
end

return M
