if vim.g.loaded_virgil then return end
vim.g.loaded_virgil = true

-- Commands resolve the module on call, so startup never loads the plugin.
local function call(fn)
  return function(a) require("virgil")[fn](a.args) end
end

local cmd = vim.api.nvim_create_user_command
cmd("Virgil", call("open"), { nargs = "?", desc = "Open a Virgil trail" })
cmd("VirgilQuit", call("quit"), { desc = "Leave the active trail" })
cmd("VirgilNext", call("next"), { desc = "Next trail step" })
cmd("VirgilPrev", call("prev"), { desc = "Previous trail step" })
cmd("VirgilSteps", call("steps"), { desc = "Pick a step in the active trail" })
cmd("VirgilQuickfix", call("to_quickfix"), { desc = "Dump the active trail into quickfix" })
