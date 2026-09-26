local plugin = require("breadcrumbs")
local store = require("breadcrumbs.store")
local trail = require("breadcrumbs.trail")

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
