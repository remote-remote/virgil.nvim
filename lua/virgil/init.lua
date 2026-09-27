local store = require("virgil.store")
local anchor = require("virgil.anchor")
local trail = require("virgil.trail")
local format = require("virgil.format")
local render = require("virgil.render")
local view = require("virgil.view")
local capture = require("virgil.capture")
local editor = require("virgil.editor")

local M = {}

-- Seam for the herdr focus adapter (later slice). Courtesy only: raising the
-- editor pane must never be load-bearing, so the no-op is a complete
-- implementation as far as the rest of the plugin is concerned.
M.focus = {
  is_available = function() return false end,
  reveal = function() end,
}

-- `deleted` is set while the open trail's file is gone from disk: the trail
-- stays readable, but nothing writes to it until the file comes back.
-- `edited` is the step the step editor has open: its index now, and the step
-- as the file held it when the editor opened or last saved.
local state = { root = nil, resolved = {}, watching = false, deleted = false, edited = nil, preview = nil }
local initialized = false
-- Defined below, once the callbacks they register exist.
local init, on_disk_change, reload

local WARN = vim.log.levels.WARN

local function notify(msg, level)
  vim.notify("[virgil] " .. msg, level or vim.log.levels.INFO)
end

local function is_blank(s)
  return type(s) ~= "string" or not s:find("%S")
end

local function abs_path(step)
  return store.abs_path(trail.data(), step)
end

local function forget_anchors()
  for _, result in pairs(state.resolved) do anchor.forget(result) end
  state.resolved = {}
end

local function resolve(index, step)
  local cached = state.resolved[index]
  if cached then
    local live = anchor.track(cached)
    if live then
      return vim.tbl_extend("force", cached, live)
    end
  end
  local file = abs_path(step)
  if not vim.uv.fs_stat(file) then
    return { status = "broken", rung = "no_match", start_line = step.range[1], end_line = step.range[1] }
  end
  local bufnr = vim.fn.bufadd(file)
  vim.fn.bufload(bufnr)
  local result = anchor.resolve(bufnr, step)
  state.resolved[index] = result
  return result
end

-- Every step, resolved. The panel's line numbers come from the live extmarks,
-- not from the JSON, so editing the file under a trail keeps the index honest.
local function entries()
  local out = {}
  for i, step in ipairs(trail.data().steps) do
    local result = resolve(i - 1, step)
    local preview = state.preview and state.preview.index == i - 1 and state.preview
    if preview then step = vim.tbl_extend("force", step, { title = preview.title, note = preview.note }) end
    table.insert(out, {
      index = i - 1,
      step = step,
      line = result.start_line or step.range[1],
      status = result.status,
      stub = is_blank(step.note),
    })
  end
  return out
end

function M.show(opts)
  opts = opts or {}
  if not trail.is_active() then return end
  local index = trail.index()
  local step = trail.current()
  if not step then return end

  local result = resolve(index, step)
  local detail = anchor.RUNG_LABEL[result.rung]
  if result.status == "exact" then detail = nil end
  local data = trail.data()
  local note = step.note
  if state.preview and state.preview.index == index then note = state.preview.note end

  view.show({
    keep_cursor = opts.keep_cursor,
    code = {
      file = abs_path(step),
      note = note,
      status = result.status,
      detail = detail,
      start_line = result.start_line or step.range[1],
      end_line = result.end_line or step.range[2] or step.range[1],
    },
    panel = {
      title = data.title or data.id or "trail",
      index = index,
      total = trail.count(),
      entries = entries(),
    },
  })

  if not state.deleted and not opts.preview then
    local ok, err = store.write_cursor(data, index)
    if not ok then notify("could not write cursor: " .. tostring(err), vim.log.levels.WARN) end
  end
  if M.focus.is_available() then M.focus.reveal() end
end

-- Editing. Every content change goes through `commit`, which saves through
-- `store.save` and then moves the in-memory trail, the live anchors and the
-- step editor's target along with it. No edit here re-derives an anchor: only
-- `capture.location` makes one, from lines someone picked.

local function same_step(a, b)
  return a.path == b.path and vim.deep_equal(a.range, b.range) and vim.deep_equal(a.anchor, b.anchor)
    and (a.title or "") == (b.title or "") and (a.note or "") == (b.note or "")
end

local function same_place(a, b)
  return a.path == b.path and vim.deep_equal(a.anchor, b.anchor)
end

-- Where `want` sits in `steps` now, trying `hint` (0-based) first.
local function find_step(steps, want, hint, match)
  match = match or same_step
  if hint and steps[hint + 1] and match(steps[hint + 1], want) then return hint end
  for i, step in ipairs(steps) do
    if match(step, want) then return i - 1 end
  end
  return nil
end

local function identity(n)
  local order = {}
  for i = 1, n do order[i] = i - 1 end
  return order
end

-- `order[new + 1]` is the old index of the step now at `new`, or false for a
-- step that did not exist. `recaptured` holds new indices whose location was
-- picked again, so their old extmark no longer describes them.
local function carry_anchors(order, recaptured)
  local old = state.resolved
  state.resolved = {}
  for i, from in ipairs(order) do
    if from ~= nil and old[from] and not (recaptured and recaptured[i - 1]) then
      state.resolved[i - 1] = old[from]
      old[from] = nil
    end
  end
  for _, result in pairs(old) do anchor.forget(result) end
end

local function follow_edited(order, steps)
  local ed = state.edited
  if not ed then return end
  for i, from in ipairs(order) do
    if from == ed.index then
      ed.index = i - 1
      ed.original = vim.deepcopy(steps[i])
      return
    end
  end
  ed.index = nil
end

-- opts.order     how the new step list maps onto the old one (default: same)
-- opts.recaptured new indices whose location was picked again
-- opts.index     the step to show afterwards
-- opts.check     false skips the revision check, for a change that finds its
--                own step in whatever is on disk
local function commit(change, opts)
  opts = opts or {}
  local data = trail.data()
  local before = store.rev(data)
  local saved, err, kind = store.save(data.__file, opts.check ~= false and before or nil, function(fresh)
    local e = change(fresh)
    if e then return e end
    if opts.index then fresh.cursor = opts.index end
  end)
  if not saved then
    if kind == "conflict" then
      notify(err .. "; reloaded it, try again", WARN)
      reload()
    elseif kind == "missing" then
      notify("the trail file is gone; nothing was saved", WARN)
    else
      notify("not saved: " .. tostring(err), WARN)
    end
    return nil, err
  end
  if store.rev(saved) == before + 1 then
    local order = opts.order or identity(#data.steps)
    carry_anchors(order, opts.recaptured)
    follow_edited(order, saved.steps)
  else
    -- Someone else wrote in between and this change was merged onto theirs.
    forget_anchors()
  end
  trail.load(saved)
  M.show({ keep_cursor = opts.keep_cursor })
  return saved
end

local function panel_title_budget()
  local numw = #tostring(math.max(trail.count(), 1))
  return math.max(view.panel_width() - (numw + 3), 8)
end

local function write_edited(title, note, force)
  local ed = state.edited
  if not trail.is_active() or not ed then
    notify("no step is being edited", WARN)
    return false
  end
  local wrote
  local saved = commit(function(fresh)
    local i = find_step(fresh.steps, ed.original, ed.index)
    if not i and force then i = find_step(fresh.steps, ed.original, ed.index, same_place) end
    if not i then
      if find_step(fresh.steps, ed.original, ed.index, same_place) then
        return "this step changed on disk since the editor opened; :w! overwrites it"
      end
      return "this step is no longer in the trail; copy your text before closing"
    end
    fresh.steps[i + 1].title = title
    fresh.steps[i + 1].note = note
    wrote = i
  end, { check = false, keep_cursor = true })
  if not saved then return false end
  -- `commit` followed the step when this was the only write; after a merge it
  -- has to be found again.
  ed.index = wrote
  ed.original = vim.deepcopy(saved.steps[wrote + 1])
  if state.preview then state.preview.index = wrote end
  return true
end

local function open_editor(index)
  local data = trail.data()
  local step = data.steps[index + 1]
  if not step then return end
  if editor.is_modified() then
    notify("the step editor has unsaved text; :w or :q! it first", WARN)
    return
  end
  state.edited = { index = index, original = vim.deepcopy(step) }
  editor.open({
    name = ("virgil://%s/%d"):format(data.id or "trail", index + 1),
    heading = ("step %d/%d · %s"):format(index + 1, #data.steps, data.title or data.id or "trail"),
    title = step.title or "",
    note = step.note or "",
    title_budget = panel_title_budget(),
    win = view.code_win(),
    on_write = write_edited,
    on_change = function(title, note)
      if not trail.is_active() or not state.edited or not state.edited.index then return end
      state.preview = { index = state.edited.index, title = title, note = note }
      M.show({ keep_cursor = true, preview = true })
    end,
    on_close = function()
      state.edited, state.preview = nil, nil
      if trail.is_active() then M.show({ keep_cursor = true, preview = true }) end
    end,
  })
  if is_blank(step.title) then vim.cmd("startinsert!") end
end

function M.edit()
  if not trail.is_active() then return notify("no active trail", WARN) end
  open_editor(trail.index())
end

-- The lines a command or mapping was given, else the cursor line.
local function picked(opts)
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local line1 = opts.line1 or vim.api.nvim_win_get_cursor(0)[1]
  return bufnr, line1, opts.line2 or line1
end

local function locate(opts, root)
  local bufnr, line1, line2 = picked(opts)
  local loc, err = capture.location(bufnr, line1, line2, root)
  if not loc then
    notify("cannot add a step here: " .. err, WARN)
    return nil
  end
  for _, w in ipairs(loc.warnings) do notify(w, WARN) end
  return loc
end

local function new_step(loc)
  return { path = loc.path, title = "", range = loc.range, anchor = loc.anchor, note = "" }
end

-- opts: line1, line2 (default: the cursor line), bufnr, quick (a stub, no
-- editor), at_end (append rather than insert after the current step).
function M.add(opts)
  opts = opts or {}
  if not initialized then init() end
  if not trail.is_active() then return M.add_to_picked(opts) end
  if state.deleted then return notify("the trail file is gone; nothing was saved", WARN) end
  local data = trail.data()
  local loc = locate(opts, store.realpath(data.root) or data.root)
  if not loc then return end
  local at = opts.at_end and #data.steps or trail.index() + 1
  local order = identity(#data.steps)
  table.insert(order, at + 1, false)
  local saved = commit(function(fresh)
    table.insert(fresh.steps, at + 1, new_step(loc))
  end, { order = order, index = at })
  if saved and not opts.quick then open_editor(at) end
  return saved
end

-- :VirgilAdd with no trail open: pick one of the repo's trails, or start one.
function M.add_to_picked(opts)
  local bufnr, line1, line2 = picked(opts)
  opts = vim.tbl_extend("force", opts, { bufnr = bufnr, line1 = line1, line2 = line2 })
  local NEW = { title = "New trail…" }
  local items = store.list(state.root)
  table.insert(items, NEW)
  vim.ui.select(items, {
    prompt = "Add to trail",
    format_item = function(t)
      if t == NEW then return t.title end
      return ("%s  (%d steps)"):format(t.title or t.id, #t.steps)
    end,
  }, function(choice)
    if not choice then return end
    if choice == NEW then return M.new(nil, opts) end
    M.start(choice)
    M.add(opts)
  end)
end

-- A trail is born with its first step, so no trail on disk is ever empty.
function M.new(title, opts)
  opts = opts or {}
  if not initialized then init() end
  local loc = locate(opts, state.root)
  if not loc then return end
  local function create(t)
    t = vim.trim(t or "")
    if t == "" then return end
    local path, id = capture.new_path(store.trails_dir(state.root), t)
    local data, err = store.create(path, { id = id, title = t, root = state.root, steps = { new_step(loc) } })
    if not data then return notify("could not create the trail: " .. tostring(err), WARN) end
    M.start(data)
    open_editor(0)
  end
  if title and vim.trim(title) ~= "" then return create(title) end
  vim.ui.input({ prompt = "Trail title: " }, create)
end

function M.start(data)
  if not initialized then init() end
  if editor.is_modified() then
    return notify("the step editor has unsaved text; :w or :q! it first", WARN)
  end
  if editor.is_open() then editor.close() end
  if not state.watching then state.watching = store.watch(state.root, on_disk_change) end
  forget_anchors()
  state.deleted = false
  trail.load(data)
  M.show()
end

function M.open(name)
  if not initialized then init() end
  local trails, errors = store.list(state.root)
  for _, e in ipairs(errors) do
    notify(("skipped %s: %s"):format(vim.fs.basename(e.path), e.err), vim.log.levels.WARN)
  end
  if #trails == 0 then
    notify("no trails for " .. state.root .. " in " .. store.trails_dir(state.root), vim.log.levels.WARN)
    return
  end
  if name and name ~= "" then
    for _, t in ipairs(trails) do
      if t.id == name then return M.start(t) end
    end
    notify("no trail with id " .. name, vim.log.levels.WARN)
    return
  end
  if #trails == 1 then return M.start(trails[1]) end
  vim.ui.select(trails, {
    prompt = "Trail",
    format_item = function(t)
      return ("%s  (%d steps)"):format(t.title or t.id, #t.steps)
    end,
  }, function(choice)
    if choice then M.start(choice) end
  end)
end

-- The teardown half of quit, without touching the windows: `view` calls this
-- when the tab or one of its windows is closed behind our back.
local function discard()
  if editor.is_open() then editor.close() end
  forget_anchors()
  state.deleted, state.edited, state.preview = false, nil, nil
  trail.unload()
end

function M.quit()
  view.close()
  discard()
end

function M.next()
  if not trail.is_active() then return M.open() end
  if not trail.next() then
    notify("end of trail")
    return
  end
  M.show()
end

function M.prev()
  if not trail.is_active() then return end
  if not trail.prev() then
    notify("start of trail")
    return
  end
  M.show()
end

function M.jump(index)
  if not trail.is_active() then return end
  if trail.jump(index) then M.show() end
end

-- What <CR> in the panel means: show the step and hand the reader the code.
function M.select(index)
  M.jump(index)
  view.focus_code()
end

function M.steps()
  if not trail.is_active() then
    notify("no active trail", vim.log.levels.WARN)
    return
  end
  local items = entries()
  vim.ui.select(items, {
    prompt = trail.data().title or "Steps",
    format_item = function(item)
      return ("%d. %s  %s:%d"):format(
        item.index + 1, format.step_title(item.step, 60), item.step.path, item.line
      )
    end,
  }, function(choice)
    if choice then M.jump(choice.index) end
  end)
end

-- The escape hatch. From inside the trail tab it closes the trail first: :cnext
-- has to be free to reuse windows, and the panel is not a window it may have.
function M.to_quickfix()
  if not trail.is_active() then
    notify("no active trail", vim.log.levels.WARN)
    return
  end
  local data = trail.data()
  local items = {}
  for _, e in ipairs(entries()) do
    table.insert(items, {
      filename = abs_path(e.step),
      lnum = e.line,
      col = 1,
      text = ("%d/%d  %s  %s"):format(
        e.index + 1, #data.steps, format.step_title(e.step, 60), (e.step.note:gsub("%s+", " "))
      ),
    })
  end
  local title = data.title or data.id or "virgil"

  if view.is_current() then M.quit() end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
end

-- Re-reads the open trail after someone else wrote it. The step editor keeps
-- its text and learns where its step went, if it is still there.
function reload()
  if not trail.is_active() then return end
  local file = trail.data().__file
  if not vim.uv.fs_stat(file) then
    if not state.deleted then
      state.deleted = true
      notify("trail deleted on disk; it reloads if the file comes back", vim.log.levels.WARN)
      M.show({ keep_cursor = true })
    end
    return
  end
  local data, err = store.read(file)
  if not data then
    notify("trail reload failed: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  state.deleted = false
  forget_anchors()
  trail.load(data)
  local ed = state.edited
  if ed then
    ed.index = find_step(data.steps, ed.original, ed.index)
      or find_step(data.steps, ed.original, ed.index, same_place)
    if state.preview then state.preview.index = ed.index end
    editor.mark_stale()
  end
  M.show({ keep_cursor = true })
end

-- `paths` is nil when the platform could not say which file changed.
function on_disk_change(paths)
  if not trail.is_active() then return end
  if paths and not vim.tbl_contains(paths, trail.data().__file) then return end
  reload()
end

function init(opts)
  opts = opts or {}
  render.setup()
  view.on_close = discard
  state.root = opts.root or store.repo_root()
  state.watching = store.watch(state.root, on_disk_change)
  initialized = true
end

-- Meant for lazy.nvim's `build`, so it reruns on every plugin install and
-- update. Prints one line per link; see install.lua for the options.
function M.install(opts)
  local install = require("virgil.install")
  local results = install.run(opts)
  if #results == 0 then
    notify("install: nothing to do, pass skills_dirs or bin_dir", vim.log.levels.WARN)
  end
  for _, r in ipairs(results) do
    notify(install.describe(r), r.action == "refused" and vim.log.levels.WARN or nil)
  end
  return results
end

-- Optional: the commands in plugin/ initialize with defaults on first use.
function M.setup(opts)
  init(opts)
end

return M
