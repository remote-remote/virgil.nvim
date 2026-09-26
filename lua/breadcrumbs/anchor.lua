-- Resolves a step against a buffer. All fuzz logic lives here.
--
-- Status is deliberately coarse: `exact` means the step is still where the trail
-- said it was, `drifted` means we found it somewhere else and you should look
-- twice, `broken` means we refuse to guess. `rung` names which step of the
-- cascade produced the answer, for the UI to explain itself.
local M = {}

M.ns = vim.api.nvim_create_namespace("breadcrumbs-anchors")

M.RUNG_LABEL = {
  exact = "anchored",
  within_symbol = "moved within its symbol",
  symbol_only = "symbol found, body changed",
  file_wide = "matched elsewhere in the file",
  unverified = "no anchor text to verify against",
  ambiguous = "anchor text is no longer unique",
  no_match = "anchor text is gone",
  out_of_range = "file is shorter than the step",
}

-- Substrings, not exact node types: grammars disagree on spelling
-- (`function_declaration`, `variable_declarator`, `method_definition`, ...).
local DECLARATION_TYPES = {
  "function", "method", "class", "struct", "interface",
  "module", "impl", "declar", "definition", "assignment", "spec",
}

local function is_declaration(node_type)
  for _, needle in ipairs(DECLARATION_TYPES) do
    if node_type:find(needle, 1, true) then return true end
  end
  return false
end

-- Pure: `lines` is the buffer as a 1-indexed array, `symbol_range` is either nil
-- or { start_line, end_line } from treesitter. Kept free of vim.api so the whole
-- cascade is testable without a buffer.
function M.locate(lines, step, symbol_range)
  local range = step.range or {}
  local start = range[1] or 1
  local span = math.max((range[2] or start) - start, 0)
  local want = step.anchor and step.anchor.text

  local function at(line)
    return {
      start_line = line,
      end_line = math.min(line + span, #lines),
    }
  end

  local function hit(line, status, rung)
    local r = at(line)
    r.status, r.rung = status, rung
    return r
  end

  if not want then
    if start > #lines then return { status = "broken", rung = "out_of_range" } end
    return hit(start, "drifted", "unverified")
  end

  if lines[start] == want then return hit(start, "exact", "exact") end

  if symbol_range then
    local last = math.min(symbol_range.end_line, #lines)
    for i = symbol_range.start_line, last do
      if lines[i] == want then return hit(i, "drifted", "within_symbol") end
    end
    return {
      status = "drifted",
      rung = "symbol_only",
      start_line = symbol_range.start_line,
      end_line = last,
    }
  end

  local found
  for i = 1, #lines do
    if lines[i] == want then
      if found then return { status = "broken", rung = "ambiguous" } end
      found = i
    end
  end
  if found then return hit(found, "drifted", "file_wide") end
  return { status = "broken", rung = "no_match" }
end

local function node_range(node)
  local srow, _, erow, ecol = node:range()
  -- treesitter end row is exclusive when end col is 0
  if ecol == 0 and erow > srow then erow = erow - 1 end
  return { start_line = srow + 1, end_line = erow + 1 }
end

local function declaring_ancestor(node)
  local n = node
  while n do
    if is_declaration(n:type()) then return n end
    n = n:parent()
  end
  return node:parent() or node
end

local function collect_by_name_field(node, symbol, bufnr, out)
  local named = node:field("name")[1]
  -- The type filter matters: lua's `variable_list` also carries a `name` field,
  -- and it spans the identifier alone, which is a useless range to anchor to.
  if named and is_declaration(node:type()) then
    local ok, text = pcall(vim.treesitter.get_node_text, named, bufnr)
    if ok and text == symbol then table.insert(out, node_range(node)) end
  end
  for child in node:iter_children() do
    if child:named() then collect_by_name_field(child, symbol, bufnr, out) end
  end
end

local function collect_by_locals(root, symbol, bufnr, lang, out)
  local ok, query = pcall(vim.treesitter.query.get, lang, "locals")
  if not ok or not query then return end
  for id, node in query:iter_captures(root, bufnr, 0, -1) do
    local capture = query.captures[id]
    if capture and capture:match("^local%.definition") then
      local got, text = pcall(vim.treesitter.get_node_text, node, bufnr)
      if got and text == symbol then
        table.insert(out, node_range(declaring_ancestor(node)))
      end
    end
  end
end

-- A trail opens files with bufadd/bufload, which does not run filetype
-- detection, so `get_parser(buf)` alone finds nothing for a buffer the user has
-- not visited yet. Fall back to deriving the language from the filename.
local function parser_for(bufnr)
  local ok, parser = pcall(vim.treesitter.get_parser, bufnr, nil, { error = false })
  if ok and parser then return parser end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return nil end
  local ft = vim.filetype.match({ filename = name })
  if not ft then return nil end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  local got, fallback = pcall(vim.treesitter.get_parser, bufnr, lang, { error = false })
  return got and fallback or nil
end

-- Best-effort. Filetypes with no parser return nil and the cascade falls back to
-- text-only anchoring rather than erroring.
function M.symbol_range(bufnr, symbol, hint_line)
  if type(symbol) ~= "string" or symbol == "" then return nil end
  local parser = parser_for(bufnr)
  if not parser then return nil end
  local parsed, trees = pcall(parser.parse, parser)
  if not parsed or not trees or not trees[1] then return nil end
  local root = trees[1]:root()

  local candidates = {}
  pcall(collect_by_name_field, root, symbol, bufnr, candidates)
  pcall(collect_by_locals, root, symbol, bufnr, parser:lang(), candidates)
  if #candidates == 0 then return nil end

  local best
  for _, c in ipairs(candidates) do
    if hint_line and c.start_line <= hint_line and hint_line <= c.end_line then
      if not best or (c.end_line - c.start_line) < (best.end_line - best.start_line) then
        best = c
      end
    end
  end
  return best or candidates[1]
end

-- Resolve against a loaded buffer and, on a hit, hand back an extmark that will
-- track live edits from here on (same gravity settings as herdr-nvim/comments).
function M.resolve(bufnr, step)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local symbol = step.anchor and step.anchor.symbol
  local hint = step.range and step.range[1]
  local symbol_range = symbol and M.symbol_range(bufnr, symbol, hint) or nil

  local result = M.locate(lines, step, symbol_range)
  result.bufnr = bufnr
  if result.status ~= "broken" then
    result.extmark = vim.api.nvim_buf_set_extmark(bufnr, M.ns, result.start_line - 1, 0, {
      end_row = result.end_line,
      end_col = 0,
      right_gravity = false,
      end_right_gravity = true,
    })
  end
  return result
end

-- Current position of a previously resolved anchor, or nil if the buffer or the
-- extmark is gone.
function M.track(result)
  if not result or not result.extmark then return nil end
  if not vim.api.nvim_buf_is_valid(result.bufnr) then return nil end
  local pos = vim.api.nvim_buf_get_extmark_by_id(result.bufnr, M.ns, result.extmark, { details = true })
  if not pos or #pos == 0 then return nil end
  local start_line = pos[1] + 1
  -- pos[3].end_row is 0-indexed exclusive, which numerically equals the
  -- 1-indexed inclusive end line.
  local end_line = pos[3] and pos[3].end_row or start_line
  if end_line < start_line then end_line = start_line end
  return { start_line = start_line, end_line = end_line }
end

function M.forget(result)
  if result and result.extmark and vim.api.nvim_buf_is_valid(result.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, result.bufnr, M.ns, result.extmark)
  end
end

return M
