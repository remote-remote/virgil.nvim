local store = require("breadcrumbs.store")

local cli = vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p")))
  .. "/bin/breadcrumbs"

-- `list` on a root with no trails prints the directory it looked in.
local function cli_trails_dir(root, env)
  local result = vim.system({ "python3", cli, "list", "--root", root }, { env = env, clear_env = true, text = true }):wait()
  T.eq(result.code, 0, result.stderr)
  return (assert(result.stdout:match("^no trails in (.-)\n$"), result.stdout))
end

local function with_env(env, fn)
  local saved = { HOME = vim.env.HOME, XDG_DATA_HOME = vim.env.XDG_DATA_HOME }
  vim.env.HOME, vim.env.XDG_DATA_HOME = env.HOME, env.XDG_DATA_HOME
  local ok, err = pcall(fn)
  vim.env.HOME, vim.env.XDG_DATA_HOME = saved.HOME, saved.XDG_DATA_HOME
  if not ok then error(err, 0) end
end

local function scratch_root()
  local dir = vim.fn.tempname() .. "/my repo é"
  vim.fn.mkdir(dir, "p")
  return store.realpath(dir)
end

T.test("storage: plugin and CLI agree on the trails dir under XDG_DATA_HOME", function()
  local root = scratch_root()
  local env = { PATH = vim.env.PATH, HOME = vim.fn.tempname(), XDG_DATA_HOME = vim.fn.tempname() }
  with_env(env, function()
    local dir = store.trails_dir(root)
    T.eq(dir:sub(1, #env.XDG_DATA_HOME + 13), env.XDG_DATA_HOME .. "/breadcrumbs/")
    T.eq(cli_trails_dir(root, env), dir)
  end)
end)

T.test("storage: plugin and CLI agree on the trails dir without XDG_DATA_HOME", function()
  local root = scratch_root()
  local env = { PATH = vim.env.PATH, HOME = vim.fn.tempname() }
  with_env(env, function()
    local dir = store.trails_dir(root)
    T.eq(dir:sub(1, #env.HOME + 26), env.HOME .. "/.local/share/breadcrumbs/")
    T.eq(cli_trails_dir(root, env), dir)
  end)
end)

T.test("storage: the repo key is readable and distinguishes same-named repos", function()
  local a, b = "/work/a/my repo é", "/work/b/my repo é"
  T.ok(store.repo_key(a):match("^my_repo___%-%x+$"), store.repo_key(a))
  T.ok(store.repo_key(a) ~= store.repo_key(b))
  T.eq(store.repo_key(a), store.repo_key(a))
end)
