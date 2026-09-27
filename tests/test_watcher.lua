local plugin = require("virgil")
local store = require("virgil.store")
local trail = require("virgil.trail")

T.test("watcher: attaches when the trails dir appears after setup", function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  root = store.realpath(root)
  vim.fn.writefile({ "local first = 1" }, root .. "/a.lua")
  local previous_tab = vim.api.nvim_get_current_tabpage()
  local ok, err = xpcall(function()
    plugin.setup({ root = root })
    T.eq(vim.uv.fs_stat(store.trails_dir(root)), nil, "setup does not create the trails dir")

    vim.fn.mkdir(store.trails_dir(root), "p")
    local file = store.trails_dir(root) .. "/late.json"
    local function write(title)
      vim.fn.writefile({ vim.json.encode({
        version = 1, id = "late", root = root, title = title, cursor = 0,
        steps = { { path = "a.lua", range = { 1, 1 }, anchor = { text = "local first = 1" }, note = "n" } },
      }) }, file)
    end
    write("before")
    plugin.start(assert(store.read(file)))
    T.eq(trail.data().title, "before")

    write("after")
    T.ok(vim.wait(2000, function() return trail.data().title == "after" end), "open trail reloaded")
  end, debug.traceback)
  plugin.quit()
  T.eq(vim.api.nvim_get_current_tabpage(), previous_tab)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(buf):sub(1, #root + 1) == root .. "/" then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end
  vim.fn.delete(store.trails_dir(root), "rf")
  vim.fn.delete(root, "rf")
  if not ok then error(err, 0) end
end)

local S = dofile(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)) .. "/support.lua")

local function with_open_trail(fn)
  local lines = { "local first = 1", "local second = 2", "return first + second" }
  local root = S.repo({ ["a.lua"] = lines })
  local ok, err = xpcall(function()
    plugin.setup({ root = root })
    local dir = store.trails_dir(root)
    local function trail_data(id, title)
      return {
        id = id, title = title, root = root,
        steps = {
          { path = "a.lua", range = { 1, 1 }, anchor = { text = lines[1] }, title = "One", note = "n" },
          { path = "a.lua", range = { 2, 2 }, anchor = { text = lines[2] }, title = "Two", note = "n" },
        },
      }
    end
    local file = dir .. "/open.json"
    plugin.start(assert(store.create(file, trail_data("open", "before"))))
    fn(root, file, dir, trail_data)
  end, debug.traceback)
  S.cleanup(root)
  if not ok then error(err, 0) end
end

T.test("watcher: another trail changing does not reload the open one", function()
  with_open_trail(function(_, _, dir, trail_data)
    local loaded = trail.data()
    assert(store.create(dir .. "/other.json", trail_data("other", "other")))
    S.write(dir .. "/other.json", S.read(dir .. "/other.json"):gsub('"other"', '"changed"'))
    vim.wait(400)
    T.ok(trail.data() == loaded, "the open trail was not reloaded")
  end)
end)

T.test("watcher: the plugin's own save does not reload, a CLI rewrite does", function()
  with_open_trail(function(root, file)
    assert(store.save(file, store.rev(trail.data()), function(data) data.title = "saved" end))
    local loaded = trail.data()
    vim.wait(400)
    T.ok(trail.data() == loaded, "own write is an echo")

    local draft = vim.json.encode({ id = "open", title = "from the cli", steps = {
      { path = "a.lua", range = { 3, 3 }, title = "Three", note = "n" },
    } })
    local code, _, stderr = S.cli(root, { "create", "--root", root, "--expect-rev", "2" }, draft)
    T.eq(code, 0, stderr)
    T.ok(vim.wait(2000, function() return trail.data().title == "from the cli" end), "reloaded")
  end)
end)

T.test("watcher: a deleted trail stays open without writes and reloads when it returns", function()
  with_open_trail(function(_, file)
    local raw = S.read(file)
    os.remove(file)
    vim.wait(400)
    T.eq(trail.data().title, "before", "still readable")
    plugin.next()
    T.eq(trail.index(), 1)
    T.eq(vim.uv.fs_stat(file), nil, "stepping wrote no cursor into a deleted trail")

    S.write(file, (raw:gsub('"before"', '"back again"')))
    T.ok(vim.wait(2000, function() return trail.data().title == "back again" end), "reloaded")
    plugin.jump(1)
    T.eq(vim.json.decode(S.read(file)).cursor, 1, "cursor writes resumed")
  end)
end)
