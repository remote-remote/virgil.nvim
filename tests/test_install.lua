local install = require("virgil.install")

local uv = vim.uv
local plugin = uv.fs_realpath(vim.fs.dirname(vim.fs.dirname(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"))))
local skill = plugin .. "/skills/virgil"

local function scratch(path)
  local dir = vim.fn.tempname() .. (path or "/skills")
  vim.fn.mkdir(dir, "p")
  return dir
end

local function actions(results)
  return vim.tbl_map(function(r) return r.action end, results)
end

T.test("install: links the skill and the CLI relatively", function()
  local skills, bin = scratch(), scratch("/bin")
  local results = install.run({ skills_dirs = { skills }, bin_dir = bin })
  T.eq(actions(results), { "created", "created" })
  local link = uv.fs_readlink(skills .. "/virgil")
  T.ok(link:sub(1, 1) ~= "/", "link is absolute: " .. link)
  T.eq(uv.fs_realpath(skills .. "/virgil"), skill)
  T.eq(uv.fs_realpath(bin .. "/virgil"), plugin .. "/bin/virgil")
end)

T.test("install: expands ~ in destination directories", function()
  local home = vim.fn.tempname()
  vim.fn.mkdir(home .. "/skills", "p")
  local saved = vim.env.HOME
  vim.env.HOME = home
  local ok, results = pcall(install.run, { skills_dirs = { "~/skills" } })
  vim.env.HOME = saved
  T.ok(ok, results)
  T.eq(actions(results), { "created" })
  T.eq(uv.fs_realpath(home .. "/skills/virgil"), skill)
end)

T.test("install: a rerun leaves correct links alone", function()
  local skills, bin = scratch(), scratch("/bin")
  install.run({ skills_dirs = { skills }, bin_dir = bin })
  T.eq(actions(install.run({ skills_dirs = { skills }, bin_dir = bin })), { "unchanged", "unchanged" })
end)

T.test("install: replaces a link left by an earlier virgil install", function()
  local skills, bin = scratch(), scratch("/bin")
  uv.fs_symlink("/old/lazy/virgil.nvim/skills/virgil", skills .. "/virgil")
  uv.fs_symlink("/old/lazy/virgil.nvim/bin/virgil", bin .. "/virgil")
  T.eq(actions(install.run({ skills_dirs = { skills }, bin_dir = bin })), { "updated", "updated" })
  T.eq(uv.fs_realpath(skills .. "/virgil"), skill)
  T.eq(uv.fs_realpath(bin .. "/virgil"), plugin .. "/bin/virgil")
end)

T.test("install: rewrites an absolute link to this plugin as relative", function()
  local skills = scratch()
  uv.fs_symlink(skill, skills .. "/virgil")
  T.eq(actions(install.run({ skills_dirs = { skills } })), { "updated" })
  T.ok(uv.fs_readlink(skills .. "/virgil"):sub(1, 1) ~= "/")
end)

T.test("install: refuses to replace a real directory or a foreign link", function()
  local real, foreign = scratch(), scratch()
  vim.fn.mkdir(real .. "/virgil")
  uv.fs_symlink("/somewhere/else/virgil", foreign .. "/virgil")
  local results = install.run({ skills_dirs = { real, foreign } })
  T.eq(actions(results), { "refused", "refused" })
  T.eq(uv.fs_lstat(real .. "/virgil").type, "directory")
  T.eq(uv.fs_readlink(foreign .. "/virgil"), "/somewhere/else/virgil")
  T.ok(install.describe(results[2]):match("/somewhere/else/virgil"), install.describe(results[2]))
end)

T.test("install: reports a missing destination instead of creating it", function()
  local missing = vim.fn.tempname() .. "/skills"
  T.eq(actions(install.run({ skills_dirs = { missing } })), { "refused" })
  T.eq(uv.fs_stat(missing), nil)
end)

T.test("install: the link resolves from the real location of a symlinked destination", function()
  local base = vim.fn.tempname()
  local real = base .. "/dotfiles/agent/.claude/skills"
  vim.fn.mkdir(real, "p")
  uv.fs_symlink(real, base .. "/skills")
  T.eq(actions(install.run({ skills_dirs = { base .. "/skills" } })), { "created" })
  T.eq(uv.fs_realpath(real .. "/virgil"), skill)
  T.eq(uv.fs_realpath(base .. "/skills/virgil"), skill)
end)

T.test("install: the CLI runs from inside the installed skill", function()
  local skills = scratch()
  install.run({ skills_dirs = { skills } })
  local repo = scratch("/repo")
  local env = { PATH = vim.env.PATH, HOME = vim.fn.tempname(), XDG_DATA_HOME = vim.fn.tempname() }
  local result = vim.system({ skills .. "/virgil/virgil", "list", "--root", repo },
    { env = env, clear_env = true, text = true }):wait()
  T.eq(result.code, 0, result.stderr)
  T.ok(result.stdout:match("^no trails in "), result.stdout)
end)

T.test("install: :VirgilInstall links the skill into each argument", function()
  vim.g.loaded_virgil = nil
  dofile(plugin .. "/plugin/virgil.lua")
  local a, b = scratch(), scratch()
  local notify = vim.notify
  local lines = {}
  vim.notify = function(msg, _) table.insert(lines, msg) end
  local ok, err = pcall(vim.cmd, ("VirgilInstall %s %s"):format(vim.fn.fnameescape(a), vim.fn.fnameescape(b)))
  vim.notify = notify
  T.ok(ok, err)
  T.eq(#lines, 2)
  T.ok(lines[1]:match("^%[virgil%] created "), lines[1])
  T.eq(uv.fs_realpath(b .. "/virgil"), skill)
end)
