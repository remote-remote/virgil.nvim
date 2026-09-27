local store = require("virgil.store")
local anchor = require("virgil.anchor")
local trail = require("virgil.trail")
local format = require("virgil.format")
local render = require("virgil.render")
local view = require("virgil.view")
local capture = require("virgil.capture")
local editor = require("virgil.editor")
local pick = require("virgil.pick")

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
-- `undo`/`redo` hold { title, steps, index } snapshots of this session's own
-- edits, and `held` the step `dd` took. `reload_pending` is an external write
-- that arrived while the reader was picking lines.
local state = {
  root = nil, resolved = {}, watching = false, deleted = false, edited = nil, preview = nil,
  undo = {}, redo = {}, held = nil, reload_pending = false,
}
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
      notice = state.deleted and "deleted on disk" or nil,
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

-- After a change nobody mapped step by step, find the edited step by content.
local function refind_edited(steps)
  local ed = state.edited
  if not ed then return end
  ed.index = find_step(steps, ed.original, ed.index) or find_step(steps, ed.original, ed.index, same_place)
  if state.preview then state.preview.index = ed.index end
end

local function follow_edited(order, steps)
  local ed = state.edited
  if not ed then return end
  if not order then return refind_edited(steps) end
  for i, from in ipairs(order) do
    if from == ed.index then
      ed.index = i - 1
      ed.original = vim.deepcopy(steps[i])
      return
    end
  end
  ed.index = nil
end

local function snapshot()
  local data = trail.data()
  return { title = data.title, steps = vim.deepcopy(data.steps), index = trail.index() }
end

-- opts.order      how the new step list maps onto the old one (default: the
--                 same; false: unknown, so live anchors are dropped)
-- opts.recaptured new indices whose location was picked again
-- opts.index      the step to show afterwards
-- opts.check      false skips the revision check, for a change that finds its
--                 own step in whatever is on disk
-- opts.record     false keeps the change off the undo stack
local function commit(change, opts)
  opts = opts or {}
  if state.deleted then
    notify("the trail file is gone; nothing was saved", WARN)
    return nil
  end
  local data = trail.data()
  local before = store.rev(data)
  local undo = opts.record ~= false and snapshot() or nil
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
    local order = opts.order
    if order == nil then order = identity(#data.steps) end
    if order then carry_anchors(order, opts.recaptured) else forget_anchors() end
    follow_edited(order or nil, saved.steps)
    if undo then
      table.insert(state.undo, undo)
      state.redo = {}
    end
  else
    -- Someone else wrote in between and this change was merged onto theirs,
    -- so the snapshots no longer describe the file.
    forget_anchors()
    refind_edited(saved.steps)
    state.undo, state.redo = {}, {}
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

-- `index` defaults to the current step; another one becomes current first, so
-- the note being written is the one on screen.
function M.edit(index)
  if not trail.is_active() then return notify("no active trail", WARN) end
  index = index or trail.index()
  if index ~= trail.index() then M.jump(index) end
  open_editor(index)
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
-- editor), after (the step to insert after, default the current one), at_end.
function M.add(opts)
  opts = opts or {}
  if not initialized then init() end
  if not trail.is_active() then return M.add_to_picked(opts) end
  if state.deleted then return notify("the trail file is gone; nothing was saved", WARN) end
  local data = trail.data()
  local loc = locate(opts, store.realpath(data.root) or data.root)
  if not loc then return end
  local at = opts.at_end and #data.steps or (opts.after or trail.index()) + 1
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

-- Panel verbs. Each acts on one step and saves at once.

local function active_step(index)
  if not trail.is_active() then
    notify("no active trail", WARN)
    return nil
  end
  index = index or trail.index()
  if not trail.step(index) then return nil end
  return index
end

-- The step's lines as the reader sees them: where it was found, or where the
-- trail says it is when it was not found at all.
local function live_lines(index)
  local step = trail.step(index)
  local result = resolve(index, step)
  local first = result.start_line or step.range[1]
  local last = result.end_line or step.range[2] or first
  return first, math.max(first, last), result
end

local function set_location(index, loc)
  return commit(function(fresh)
    local step = fresh.steps[index + 1]
    step.path, step.range, step.anchor = loc.path, loc.range, loc.anchor
  end, { index = index, recaptured = { [index] = true } })
end

-- :VirgilRange: move the current step to the given lines.
function M.set_range(opts)
  opts = opts or {}
  local index = active_step(opts.index)
  if not index then return end
  local data = trail.data()
  local loc = locate(opts, store.realpath(data.root) or data.root)
  if loc then return set_location(index, loc) end
end

local function code_window_for(index)
  if not view.is_open() then return nil end
  if index and index ~= trail.index() then M.jump(index) end
  return view.code_win()
end

local function start_pick(win, opts)
  local on_done = opts.on_done
  pick.start(win, {
    message = opts.message,
    select = opts.select,
    on_done = on_done,
    on_end = function()
      if state.reload_pending then
        state.reload_pending = false
        reload()
      end
    end,
  })
end

-- `a` and `A` in the panel: pick lines in the code window for a new step.
function M.pick_add(index, at_end)
  index = active_step(index)
  if not index then return end
  local win = code_window_for(index)
  if not win then return end
  local where = at_end and "at the end" or ("after " .. (index + 1))
  start_pick(win, {
    message = "lines for a new step " .. where,
    on_done = function(bufnr, line1, line2)
      M.add({ bufnr = bufnr, line1 = line1, line2 = line2, after = index, at_end = at_end })
    end,
  })
end

-- `R` in the panel: the step's lines, preselected, for the reader to adjust.
function M.pick_range(index)
  index = active_step(index)
  if not index then return end
  local win = code_window_for(index)
  if not win then return end
  local first, last = live_lines(index)
  start_pick(win, {
    message = ("new lines for step %d"):format(index + 1),
    select = { first, last },
    on_done = function(bufnr, line1, line2)
      M.set_range({ index = index, bufnr = bufnr, line1 = line1, line2 = line2 })
    end,
  })
end

-- `=`: take the place a drifted step was found by its anchor text as its
-- location. A step found only by its symbol has no such place.
function M.accept_drift(index)
  index = active_step(index)
  if not index then return end
  local first, last, result = live_lines(index)
  if result.status == "exact" then return notify("step " .. (index + 1) .. " is already where the trail says") end
  if result.status == "broken" then
    return notify("step " .. (index + 1) .. " was not found; pick its lines with R", WARN)
  end
  if result.rung == "symbol_only" then
    return notify("only the symbol of step " .. (index + 1) .. " was found; pick its lines with R", WARN)
  end
  local data = trail.data()
  local loc, err = capture.location(result.bufnr, first, last, store.realpath(data.root) or data.root)
  if not loc then return notify("cannot re-anchor: " .. err, WARN) end
  for _, w in ipairs(loc.warnings) do notify(w, WARN) end
  return set_location(index, loc)
end

-- `r`: a one-line retitle.
function M.retitle(index)
  index = active_step(index)
  if not index then return end
  vim.ui.input({ prompt = "Step title: ", default = trail.step(index).title or "" }, function(title)
    if title == nil then return end
    commit(function(fresh) fresh.steps[index + 1].title = vim.trim(title) end, { keep_cursor = true })
  end)
end

-- :VirgilRename and `r` on the panel header. The id, and so the file name and
-- every `:Virgil <id>`, stay the same.
function M.rename(title)
  if not trail.is_active() then return notify("no active trail", WARN) end
  local function apply(t)
    t = vim.trim(t or "")
    if t == "" then return end
    commit(function(fresh) fresh.title = t end, { keep_cursor = true })
  end
  if title and vim.trim(title) ~= "" then return apply(title) end
  vim.ui.input({ prompt = "Trail title: ", default = trail.data().title or "" }, apply)
end

-- `dd`: delete the step and hold it for `p`/`P`.
function M.delete_step(index)
  index = active_step(index)
  if not index then return end
  local n = trail.count()
  if n == 1 then
    return notify("a trail needs a step; use :VirgilDelete to delete the whole trail", WARN)
  end
  local held = vim.deepcopy(trail.step(index))
  local order = identity(n)
  table.remove(order, index + 1)
  local saved = commit(function(fresh) table.remove(fresh.steps, index + 1) end, {
    order = order,
    index = math.min(index, n - 2),
  })
  if saved then state.held = held end
  return saved
end

-- `p` / `P`: put the held step after / before a step. Its anchor comes with it.
function M.put(index, before)
  index = active_step(index)
  if not index then return end
  if not state.held then return notify("no step held; dd holds one", WARN) end
  local at = before and index or index + 1
  local order = identity(trail.count())
  table.insert(order, at + 1, false)
  local step = vim.deepcopy(state.held)
  return commit(function(fresh) table.insert(fresh.steps, at + 1, step) end, { order = order, index = at })
end

-- `J` / `K`: move a step down or up by `delta` places.
function M.move(index, delta)
  index = active_step(index)
  if not index then return end
  local n = trail.count()
  local to = math.max(0, math.min(n - 1, index + delta))
  if to == index then return end
  local order = identity(n)
  table.insert(order, to + 1, table.remove(order, index + 1))
  return commit(function(fresh)
    table.insert(fresh.steps, to + 1, table.remove(fresh.steps, index + 1))
  end, { order = order, index = to })
end

local function restore(from, to)
  local snap = table.remove(from)
  if not snap then return false end
  local current = snapshot()
  local saved = commit(function(fresh)
    fresh.title = snap.title
    fresh.steps = vim.deepcopy(snap.steps)
  end, { order = false, index = math.min(snap.index, #snap.steps - 1), record = false })
  if saved then table.insert(to, current) end
  return true
end

-- `u` / `<C-r>`: step back and forth through this session's edits. Each one is
-- an ordinary content write; an edit from outside clears both stacks.
function M.undo()
  if not trail.is_active() then return end
  if not restore(state.undo, state.redo) then notify("nothing to undo") end
end

function M.redo()
  if not trail.is_active() then return end
  if not restore(state.redo, state.undo) then notify("nothing to redo") end
end

-- :VirgilDelete: the active trail, or the one named, after a confirmation.
function M.delete(id)
  if not initialized then init() end
  local function remove(t)
    local label = t.title or t.id
    local choice = vim.fn.confirm(("Delete trail %q permanently?"):format(label), "&Delete\n&Cancel", 2)
    if choice ~= 1 then return end
    local file = t.__file
    if trail.is_active() and trail.data().__file == file then M.quit() end
    local ok, err = store.delete(file)
    if not ok then return notify("could not delete: " .. tostring(err), WARN) end
    notify("deleted " .. label)
  end
  if (not id or id == "") and trail.is_active() then return remove(trail.data()) end
  local trails = store.list(state.root)
  if id and id ~= "" then
    for _, t in ipairs(trails) do
      if t.id == id then return remove(t) end
    end
    return notify("no trail with id " .. id, WARN)
  end
  if #trails == 0 then return notify("no trails to delete", WARN) end
  vim.ui.select(trails, {
    prompt = "Delete trail",
    format_item = function(t) return ("%s  (%d steps)"):format(t.title or t.id, #t.steps) end,
  }, function(choice)
    if choice then remove(choice) end
  end)
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
  if pick.active() then pick.cancel() end
  if editor.is_open() then editor.close() end
  forget_anchors()
  state.deleted, state.edited, state.preview = false, nil, nil
  state.undo, state.redo, state.held, state.reload_pending = {}, {}, nil, false
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
  state.undo, state.redo = {}, {}
  forget_anchors()
  trail.load(data)
  if state.edited then
    refind_edited(data.steps)
    editor.mark_stale()
  end
  M.show({ keep_cursor = true })
end

-- `paths` is nil when the platform could not say which file changed.
function on_disk_change(paths)
  if not trail.is_active() then return end
  if paths and not vim.tbl_contains(paths, trail.data().__file) then return end
  -- A redraw would move the code window's cursor and lose the selection.
  if pick.active() then
    state.reload_pending = true
    return
  end
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
