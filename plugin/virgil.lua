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
-- The lines a command was given; with no range, the capture uses the cursor line.
local function lines(a)
  if a.range == 0 then return {} end
  return { line1 = a.line1, line2 = a.line2 }
end
cmd("VirgilNew", function(a)
  require("virgil").new(a.args, lines(a))
end, { nargs = "?", range = true, desc = "Start a Virgil trail at this line or selection" })
cmd("VirgilAdd", function(a)
  require("virgil").add(vim.tbl_extend("force", lines(a), { quick = a.bang }))
end, { range = true, bang = true, desc = "Add this line or selection as a trail step (! skips the editor)" })
cmd("VirgilEdit", call("edit"), { desc = "Edit the current step's title and note" })
cmd("VirgilInstall", function(a)
  require("virgil").install({ skills_dirs = a.fargs })
end, { nargs = "+", complete = "dir", desc = "Link the Virgil agent skill into skills directories" })
