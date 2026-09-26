local store = require("breadcrumbs.store")
local anchor = require("breadcrumbs.anchor")
local trail = require("breadcrumbs.trail")
local format = require("breadcrumbs.format")
local render = require("breadcrumbs.render")
local view = require("breadcrumbs.view")

local M = {}

-- Seam for the herdr focus adapter (later slice). Courtesy only: raising the
-- editor pane must never be load-bearing, so the no-op is a complete
-- implementation as far as the rest of the plugin is concerned.
M.focus = {
  is_available = function() return false end,
  reveal = function() end,
}

local state = { root = nil, resolved = {} }
local initialized = false
-- Defined below, once the callbacks it registers exist.
local init

local function notify(msg, level)
  vim.notify("[breadcrumbs] " .. msg, level or vim.log.levels.INFO)
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
    table.insert(out, {
      index = i - 1,
      step = step,
      line = result.start_line or step.range[1],
      status = result.status,
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

  view.show({
    keep_cursor = opts.keep_cursor,
    code = {
      file = abs_path(step),
      note = step.note,
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

  local ok, err = store.write_cursor(data, index)
  if not ok then notify("could not write cursor: " .. tostring(err), vim.log.levels.WARN) end
  if M.focus.is_available() then M.focus.reveal() end
end

function M.start(data)
  if not initialized then init() end
  forget_anchors()
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
  forget_anchors()
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
  local title = data.title or data.id or "breadcrumbs"

  if view.is_current() then M.quit() end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
end

local function on_disk_change()
  if not trail.is_active() then return end
  local file = trail.data().__file
  local data, err = store.read(file)
  if not data then
    notify("trail reload failed: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  forget_anchors()
  trail.load(data)
  M.show({ keep_cursor = true })
end

function init(opts)
  opts = opts or {}
  render.setup()
  view.on_close = discard
  state.root = opts.root or store.repo_root()
  store.watch(state.root, on_disk_change)
  initialized = true
end

-- Optional: the commands in plugin/ initialize with defaults on first use.
function M.setup(opts)
  init(opts)
end

return M
