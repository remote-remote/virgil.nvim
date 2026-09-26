-- Pure state: the loaded trail and where you are in it. No vim.api here, ever.
-- Index is 0-based to match the `cursor` field on disk.
local M = {}

local state = { data = nil, index = 0 }

local function clamp(i, count)
  if count == 0 then return 0 end
  if i < 0 then return 0 end
  if i > count - 1 then return count - 1 end
  return i
end

function M.load(data)
  state.data = data
  state.index = clamp(tonumber(data and data.cursor) or 0, M.count())
  return M.current()
end

function M.unload()
  state.data, state.index = nil, 0
end

function M.is_active()
  return state.data ~= nil
end

function M.data()
  return state.data
end

function M.count()
  if not state.data then return 0 end
  return #state.data.steps
end

function M.index()
  return state.index
end

function M.step(i)
  if not state.data then return nil end
  return state.data.steps[i + 1]
end

function M.current()
  return M.step(state.index)
end

-- Returns whether the index actually moved, so callers can distinguish "stepped"
-- from "already at the end" without duplicating the clamp.
function M.jump(i)
  local target = clamp(i, M.count())
  if not state.data or target == state.index then return false end
  state.index = target
  return true
end

function M.next()
  return M.jump(state.index + 1)
end

function M.prev()
  return M.jump(state.index - 1)
end

function M.at_start()
  return state.index == 0
end

function M.at_end()
  return M.count() == 0 or state.index == M.count() - 1
end

return M
