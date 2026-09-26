if vim.g.loaded_breadcrumbs then return end
vim.g.loaded_breadcrumbs = true

-- Commands resolve the module on call, so startup never loads the plugin.
local function call(fn)
  return function(a) require("breadcrumbs")[fn](a.args) end
end

local cmd = vim.api.nvim_create_user_command
cmd("Breadcrumbs", call("open"), { nargs = "?", desc = "Open a breadcrumb trail" })
cmd("BreadcrumbsQuit", call("quit"), { desc = "Leave the active trail" })
cmd("BreadcrumbsNext", call("next"), { desc = "Next trail step" })
cmd("BreadcrumbsPrev", call("prev"), { desc = "Previous trail step" })
cmd("BreadcrumbsSteps", call("steps"), { desc = "Pick a step in the active trail" })
cmd("BreadcrumbsQuickfix", call("to_quickfix"), { desc = "Dump the active trail into quickfix" })
