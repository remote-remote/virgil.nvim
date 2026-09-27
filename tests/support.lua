-- Shared fixtures for the suite: scratch repos, file IO, and the CLI.
local store = require("virgil.store")

local M = {}

M.tests_dir = vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))
M.cli_path = vim.fs.dirname(M.tests_dir) .. "/bin/virgil"

function M.read(path)
  local fd = assert(io.open(path, "r"))
  local raw = fd:read("*a")
  fd:close()
  return raw
end

function M.write(path, raw)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local fd = assert(io.open(path, "w"))
  fd:write(raw)
  fd:close()
end

-- A realpath'd scratch root with its trails dir, and `files` ({ name = lines })
-- written into it.
function M.repo(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = store.realpath(root)
  vim.fn.mkdir(store.trails_dir(root), "p")
  for name, lines in pairs(files or {}) do
    vim.fn.mkdir(vim.fs.dirname(root .. "/" .. name), "p")
    vim.fn.writefile(lines, root .. "/" .. name)
  end
  return root
end

-- Runs bin/virgil from `root`. Returns code, stdout, stderr.
function M.cli(root, args, stdin, env)
  local cmd = { "python3", M.cli_path }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = root, stdin = stdin, text = true, env = env }):wait()
  return r.code, r.stdout, r.stderr
end

-- Leaves no loaded buffer, trail file or tab behind a test that opened a trail.
function M.cleanup(root)
  pcall(require("virgil").quit)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:sub(1, #root + 1) == root .. "/" or name:match("^virgil://") then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(store.trails_dir(root), "rf")
  vim.fn.delete(root, "rf")
end

return M
