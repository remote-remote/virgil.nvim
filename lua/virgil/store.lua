-- On-disk format, root matching, the watcher, and every write to a trail file.
-- The only module that knows JSON exists.
local M = {}

local LUANIL = { luanil = { object = true, array = true } }
local self_writes = {}
local watcher = { handle = nil, timer = nil, pending = {}, blind = false }

local function realpath(p)
  if type(p) ~= "string" or p == "" then return nil end
  return vim.uv.fs_realpath(p) or p
end

local function slurp(path)
  local fd = io.open(path, "r")
  if not fd then return nil end
  local raw = fd:read("*a")
  fd:close()
  return raw
end

-- Temp file plus rename, so neither the watcher nor the CLI ever reads half a
-- trail. The pid keeps this writer's temp file apart from the CLI's.
local function spit(path, raw)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local tmp = ("%s.%d.tmp"):format(path, vim.uv.os_getpid())
  local fd, err = io.open(tmp, "w")
  if not fd then return false, err end
  local ok, werr = fd:write(raw)
  fd:close()
  if ok then ok, werr = vim.uv.fs_rename(tmp, path) end
  if not ok then
    os.remove(tmp)
    return false, werr
  end
  return true
end

M.realpath = realpath

function M.repo_root(start)
  start = start or vim.uv.cwd()
  local marker = vim.fs.root(start, ".git")
  return realpath(marker or start)
end

-- Trails live outside the repo they describe. The layout rule is documented
-- under "Storage" in the README, and bin/virgil derives the same path.
function M.data_home()
  local xdg = vim.env.XDG_DATA_HOME
  if xdg and xdg ~= "" then return xdg end
  return vim.env.HOME .. "/.local/share"
end

function M.repo_key(root)
  local base = vim.fs.basename(root):gsub("[^A-Za-z0-9._-]", "_")
  if base == "" then base = "root" end
  return base .. "-" .. vim.fn.sha256(root):sub(1, 12)
end

function M.trails_dir(root)
  root = root or M.repo_root()
  return M.data_home() .. "/virgil/" .. M.repo_key(root)
end

function M.validate(data)
  if type(data) ~= "table" then return "not a json object" end
  if data.version ~= 1 then return "unsupported version: " .. tostring(data.version) end
  if type(data.root) ~= "string" then return "missing root" end
  if type(data.steps) ~= "table" or #data.steps == 0 then return "no steps" end
  for i, step in ipairs(data.steps) do
    if type(step.path) ~= "string" then return ("step %d: missing path"):format(i) end
    if type(step.range) ~= "table" or type(step.range[1]) ~= "number" then
      return ("step %d: range must be [start, end]"):format(i)
    end
    if type(step.note) ~= "string" then return ("step %d: missing note"):format(i) end
  end
  return nil
end

function M.decode(raw, path)
  local ok, data = pcall(vim.json.decode, raw, LUANIL)
  if not ok then return nil, "invalid json: " .. tostring(data) end
  local err = M.validate(data)
  if err then return nil, err end
  data.__file = path
  return data
end

function M.read(path)
  local raw = slurp(path)
  if not raw then return nil, "cannot read " .. path end
  return M.decode(raw, path)
end

-- Returns trails whose `root` resolves to `root`, plus a list of {path, err}
-- for files that failed to parse so a typo is visible rather than silent.
function M.list(root)
  root = root or M.repo_root()
  local dir = M.trails_dir(root)
  local trails, errors = {}, {}
  if not vim.uv.fs_stat(dir) then return trails, errors end
  for name, kind in vim.fs.dir(dir) do
    if kind == "file" and name:match("%.json$") then
      local path = dir .. "/" .. name
      local data, err = M.read(path)
      if data then
        if realpath(data.root) == root then table.insert(trails, data) end
      else
        table.insert(errors, { path = path, err = err })
      end
    end
  end
  table.sort(trails, function(a, b)
    return (a.title or a.id or a.__file) < (b.title or b.id or b.__file)
  end)
  return trails, errors
end

-- Rewrites `cursor` in the raw text instead of re-encoding, so a hand-authored
-- trail keeps its formatting, key order and comments-in-prose intact. The patch
-- is decoded and diffed against the original before it is trusted: a note
-- containing the literal text `"cursor": 3` would otherwise be a plausible
-- mis-target for the pattern.
function M.patch_cursor(raw, index)
  local ok, before = pcall(vim.json.decode, raw, LUANIL)
  if not ok then return nil, "invalid json" end
  before.__file = nil

  local candidates = {}
  local from = 1
  while true do
    local s, e, prefix = raw:find('("cursor"%s*:%s*)%-?%d+', from)
    if not s then break end
    table.insert(candidates, raw:sub(1, s - 1) .. prefix .. tostring(index) .. raw:sub(e + 1))
    from = e + 1
  end
  local inserted, n = raw:gsub("^(%s*{)", '%1\n  "cursor": ' .. tostring(index) .. ",", 1)
  if n == 1 then table.insert(candidates, inserted) end

  for _, candidate in ipairs(candidates) do
    local decoded_ok, after = pcall(vim.json.decode, candidate, LUANIL)
    if decoded_ok and after.cursor == index then
      after.cursor = before.cursor
      if vim.deep_equal(before, after) then return candidate end
    end
  end

  before.cursor = index
  return M.encode(before)
end

function M.write_cursor(data, index)
  local path = data and data.__file
  if not path then return false, "trail is not backed by a file" end
  local raw = slurp(path)
  if not raw then return false, "cannot read " .. path end
  local patched, err = M.patch_cursor(raw, index)
  if not patched then return false, err end
  data.cursor = index
  if patched == raw then return true end
  local ok, werr = spit(path, patched)
  if not ok then return false, werr end
  self_writes[path] = patched
  return true
end

-- The write contract, shared with bin/virgil and written down in the README's
-- "Trail file format and write rules". `encode` produces the bytes Python's
-- json.dumps(indent=2, ensure_ascii=False) does for the same key order, so a
-- trail written by either side round-trips through the other unchanged.
-- vim.json cannot: before 0.12 it has no indent and escapes every `/`.
local TRAIL_KEYS = {
  "version", "id", "title", "root", "author", "created_at",
  "updated_by", "updated_at", "rev", "cursor", "steps",
}
local STEP_KEYS = { "path", "title", "range", "anchor", "note" }
local ANCHOR_KEYS = { "text", "symbol" }
local PERSON_KEYS = { "kind", "name" }

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function quote(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    if c == "\127" then return c end
    return ESCAPES[c] or ("\\u%04x"):format(c:byte())
  end) .. '"'
end

-- vim.json.decode marks `{}` with the empty-dict metatable and leaves `[]`
-- bare, which is the only way to tell the two apart once decoded.
local function is_object(t)
  if type(t) ~= "table" then return false end
  if getmetatable(t) == vim._empty_dict_mt then return true end
  return next(t) ~= nil and not vim.islist(t)
end

local function is_array(t)
  return type(t) == "table" and not is_object(t)
end

-- Known keys in contract order, then the rest sorted, the same as `ordered` in
-- bin/virgil.
local function key_order(t, known)
  local keys, seen = {}, {}
  for _, k in ipairs(known or {}) do
    if t[k] ~= nil then
      table.insert(keys, k)
      seen[k] = true
    end
  end
  local rest = {}
  for k in pairs(t) do
    if type(k) == "string" and not seen[k] and k ~= "__file" then table.insert(rest, k) end
  end
  table.sort(rest)
  vim.list_extend(keys, rest)
  return keys
end

local encode_value

local function encode_object(t, indent, known, schema)
  local keys = key_order(t, known)
  if #keys == 0 then return "{}" end
  local inner = indent .. "  "
  local parts = {}
  for _, k in ipairs(keys) do
    local sub = schema and schema[k]
    table.insert(parts, inner .. quote(k) .. ": " .. encode_value(t[k], inner, sub))
  end
  return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
end

local function encode_array(t, indent, item)
  if #t == 0 then return "[]" end
  local inner = indent .. "  "
  local parts = {}
  for i = 1, #t do
    table.insert(parts, inner .. encode_value(t[i] == nil and vim.NIL or t[i], inner, item))
  end
  return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
end

-- `shape` is how the contract lays out this value: a list of known keys for an
-- object, or { item = shape } for an array of them.
function encode_value(v, indent, shape)
  local kind = type(v)
  if v == vim.NIL or v == nil then return "null" end
  if kind == "boolean" then return tostring(v) end
  if kind == "number" then
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  end
  if kind == "string" then return quote(v) end
  if kind ~= "table" then error("cannot encode a " .. kind) end
  if shape and shape.item then return encode_array(v, indent, shape.item) end
  if shape or is_object(v) then
    return encode_object(v, indent, shape and shape.keys, shape and shape.schema)
  end
  return encode_array(v, indent, nil)
end

local STEP_SHAPE = { keys = STEP_KEYS, schema = { anchor = { keys = ANCHOR_KEYS } } }
local TRAIL_SHAPE = {
  keys = TRAIL_KEYS,
  schema = {
    author = { keys = PERSON_KEYS },
    updated_by = { keys = PERSON_KEYS },
    steps = { item = STEP_SHAPE },
  },
}

function M.encode(data)
  return encode_value(data, "", TRAIL_SHAPE) .. "\n"
end

local function is_int(v)
  return type(v) == "number" and v == math.floor(v)
end

local function is_blank(s)
  return type(s) ~= "string" or vim.trim(s) == ""
end

-- The first way a trail breaks the write contract, or nil. Stricter than
-- `validate`, which only asks whether the reader can show a trail: writes are
-- held to what bin/virgil's validate_trail enforces, message for message.
-- Expects a decode that keeps nulls as vim.NIL, so `"title": null` is caught
-- here as it is in Python.
function M.check(data)
  if not is_object(data) then return "not a json object" end
  if data.version ~= 1 then return "version: must be 1" end
  if type(data.id) ~= "string" or not data.id:match("^[A-Za-z0-9._-]+$") then
    return "id: must be a filename of letters, digits, . _ -"
  end
  if is_blank(data.title) then return "title: required" end
  if type(data.root) ~= "string" or data.root == "" then return "root: required" end
  for _, key in ipairs({ "author", "updated_by" }) do
    if data[key] ~= nil and not is_object(data[key]) then return key .. ": must be an object" end
  end
  for _, key in ipairs({ "rev", "cursor" }) do
    if data[key] ~= nil and (not is_int(data[key]) or data[key] < 0) then
      return key .. ": must be a non-negative integer"
    end
  end
  local steps = data.steps
  if not is_array(steps) or #steps == 0 then return "steps: required, a non-empty list" end
  for i, step in ipairs(steps) do
    local where = ("step %d"):format(i)
    if not is_object(step) then return where .. ": not an object" end
    if type(step.path) ~= "string" or step.path == "" then return where .. ": path is required" end
    local r = step.range
    if not is_array(r) or #r ~= 2 or not is_int(r[1]) or not is_int(r[2])
        or r[1] < 1 or r[2] < r[1] then
      return where .. ": range must be [start, end] with 1 <= start <= end"
    end
    local a = step.anchor
    if not is_object(a) or is_blank(a.text) then
      return where .. ": anchor.text is required and must not be blank"
    end
    if a.symbol ~= nil and type(a.symbol) ~= "string" then
      return where .. ": anchor.symbol must be a string"
    end
    if step.title ~= nil and type(step.title) ~= "string" then
      return where .. ": title must be a string"
    end
    if type(step.note) ~= "string" then return where .. ": note must be a string" end
  end
  return nil
end

-- A trail with no `rev` predates the counter, which is the same as rev 0.
function M.rev(data)
  local rev = data and data.rev
  return is_int(rev) and rev or 0
end

function M.author()
  local name = vim.env.VIRGIL_AUTHOR
  if not name or name == "" then name = vim.env.USER end
  return { kind = "human", name = (name and name ~= "") and name or "human" }
end

-- Who wrote the trail last, for messages: updated_by, else the creator.
function M.describe_editor(data)
  for _, key in ipairs({ "updated_by", "author" }) do
    local who = data[key]
    if is_object(who) then
      local kind = type(who.kind) == "string" and who.kind or "unknown"
      return type(who.name) == "string" and (kind .. " " .. who.name) or kind
    end
  end
  return "unknown"
end

function M.now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

-- Checks, writes, and hands back the trail as the reader decodes it, so the
-- caller never holds vim.NIL or a stale copy.
local function write_trail(path, data)
  local err = M.check(data)
  if err then return nil, err, "invalid" end
  local raw = M.encode(data)
  local ok, werr = spit(path, raw)
  if not ok then return nil, werr, "io" end
  self_writes[path] = raw
  return M.decode(raw, path)
end

-- A content write: re-read the file, refuse unless it is still at `base_rev`,
-- let `change` edit the decoded trail in place, then stamp, check and write it.
-- `change` may return an error string to abort. Anchors are whatever `change`
-- leaves on each step; nothing here re-derives one.
--
-- Returns the written trail (with `__file`), or nil, an error, and a kind:
-- "missing", "conflict", "invalid" or "io".
function M.save(path, base_rev, change)
  local raw = slurp(path)
  if not raw then return nil, "cannot read " .. path, "missing" end
  -- Nulls stay vim.NIL here, so fields this plugin does not know round-trip
  -- exactly and `check` sees what Python would.
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= "table" then return nil, "invalid json in " .. path, "invalid" end
  local rev = M.rev(data)
  if base_rev ~= nil and rev ~= base_rev then
    return nil, ("the trail changed on disk (rev %d, last edited by %s)"):format(
      rev, M.describe_editor(data)), "conflict"
  end
  local err = change(data)
  if err then return nil, err, "invalid" end
  data.updated_by = M.author()
  data.updated_at = M.now()
  data.rev = rev + 1
  return write_trail(path, data)
end

-- A brand-new trail file. Refuses an existing path: two people picking the
-- same title must never overwrite each other.
function M.create(path, data)
  if vim.uv.fs_stat(path) then return nil, "a trail already exists at " .. path end
  local who = M.author()
  local stamp = M.now()
  data.version = 1
  data.author = data.author or who
  data.created_at = data.created_at or stamp
  data.updated_by = who
  data.updated_at = stamp
  data.rev = 1
  data.cursor = data.cursor or 0
  return write_trail(path, data)
end

function M.delete(path)
  self_writes[path] = nil
  local ok, err = os.remove(path)
  if not ok then return false, err end
  return true
end

-- Calls `cb(paths)` with the trail files somebody else changed, or `cb(nil)`
-- when the platform did not say which file changed and it was not our echo.
local function drain(cb)
  local paths = vim.tbl_keys(watcher.pending)
  local blind = watcher.blind
  watcher.pending, watcher.blind = {}, false

  if blind and #paths == 0 then
    -- Consume one pending echo, otherwise assume the change was somebody else's.
    for path, content in pairs(self_writes) do
      if slurp(path) == content then
        self_writes[path] = nil
        return
      end
    end
    return cb(nil)
  end
  local external = {}
  for _, path in ipairs(paths) do
    if self_writes[path] and slurp(path) == self_writes[path] then
      self_writes[path] = nil
    else
      table.insert(external, path)
    end
  end
  if #external > 0 then cb(external) end
end

-- fs_event fires several times for one save (editors write a temp file and
-- rename over the target), so the debounce is not optional: without it a single
-- write re-renders the trail three times. Only `.json` names count: the temp
-- files both writers rename from are never a trail.
function M.watch(root, cb)
  M.unwatch()
  local dir = M.trails_dir(root)
  if not vim.uv.fs_stat(dir) then return false end
  local handle = vim.uv.new_fs_event()
  local timer = vim.uv.new_timer()
  if not handle or not timer then return false end
  watcher.handle, watcher.timer = handle, timer

  local ok = pcall(handle.start, handle, dir, {}, function(err, filename)
    if err then return end
    if filename then
      if not filename:match("%.json$") then return end
      watcher.pending[dir .. "/" .. vim.fs.basename(filename)] = true
    else
      watcher.blind = true
    end
    timer:stop()
    timer:start(120, 0, function()
      vim.schedule(function() drain(cb) end)
    end)
  end)
  if not ok then
    M.unwatch()
    return false
  end
  return true
end

function M.unwatch()
  if watcher.timer then
    watcher.timer:stop()
    watcher.timer:close()
  end
  if watcher.handle then
    watcher.handle:stop()
    watcher.handle:close()
  end
  watcher = { handle = nil, timer = nil, pending = {}, blind = false }
end

function M.abs_path(data, step)
  if step.path:sub(1, 1) == "/" then return step.path end
  return data.root .. "/" .. step.path
end

return M
