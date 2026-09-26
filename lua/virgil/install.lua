-- Links the agent skill (and optionally the CLI) out of the plugin checkout.
-- The links point into the plugin's install location, so a plugin update moves
-- what they resolve to and nothing has to be reinstalled.
local M = {}

local uv = vim.uv

-- lua/virgil/install.lua -> the plugin root.
local function plugin_root()
  local here = debug.getinfo(1, "S").source:sub(2)
  return uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
end

local function parts(path)
  return vim.split(path, "/", { plain = true, trimempty = true })
end

-- Both paths absolute and already resolved.
function M.relative(from_dir, to)
  local from, dest = parts(from_dir), parts(to)
  local common = 0
  while common < #from and common < #dest and from[common + 1] == dest[common + 1] do
    common = common + 1
  end
  local out = {}
  for _ = common + 1, #from do table.insert(out, "..") end
  for i = common + 1, #dest do table.insert(out, dest[i]) end
  return #out == 0 and "." or table.concat(out, "/")
end

-- A link left by an earlier install, possibly from a different plugin path.
-- `suffix` is where the target sits inside the plugin, e.g. "skills/virgil".
local function ours(target, link, suffix, want)
  if target:sub(-#("virgil.nvim/" .. suffix)) == "virgil.nvim/" .. suffix then return true end
  return uv.fs_realpath(link) == want
end

local function link_one(dir, target, suffix)
  local link = vim.fs.joinpath(dir, "virgil")
  local real_dir = uv.fs_realpath(dir)
  if not real_dir or vim.fn.isdirectory(real_dir) == 0 then
    return { action = "refused", path = link, reason = dir .. " does not exist" }
  end
  local rel = M.relative(real_dir, target)

  local stat = uv.fs_lstat(link)
  if stat then
    if stat.type ~= "link" then
      return { action = "refused", path = link, reason = "a " .. stat.type .. " is already there" }
    end
    local current = uv.fs_readlink(link)
    if current == rel then return { action = "unchanged", path = link, target = rel } end
    if not ours(current, link, suffix, target) then
      return { action = "refused", path = link, reason = "it links to " .. current }
    end
    local ok, err = uv.fs_unlink(link)
    if not ok then return { action = "refused", path = link, reason = err } end
    ok, err = uv.fs_symlink(rel, link)
    if not ok then return { action = "refused", path = link, reason = err } end
    return { action = "updated", path = link, target = rel }
  end

  local ok, err = uv.fs_symlink(rel, link)
  if not ok then return { action = "refused", path = link, reason = err } end
  return { action = "created", path = link, target = rel }
end

-- opts.skills_dirs: directories that get a `virgil` link to skills/virgil.
-- opts.bin_dir: optional directory that gets a `virgil` link to bin/virgil.
-- Returns one result per link: { action, path, target | reason }.
function M.run(opts)
  opts = opts or {}
  local root = opts.plugin_root or plugin_root()
  local results = {}
  for _, dir in ipairs(opts.skills_dirs or {}) do
    table.insert(results, link_one(vim.fs.normalize(dir), root .. "/skills/virgil", "skills/virgil"))
  end
  if opts.bin_dir then
    table.insert(results, link_one(vim.fs.normalize(opts.bin_dir), root .. "/bin/virgil", "bin/virgil"))
  end
  return results
end

function M.describe(result)
  if result.action == "refused" then
    return ("refused %s: %s"):format(result.path, result.reason)
  end
  return ("%s %s -> %s"):format(result.action, result.path, result.target)
end

return M
