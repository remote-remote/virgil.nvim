# virgil.nvim

Guided code trails humans and agents build, read, and hand to each other.

The name comes from Virgil, Dante's guide through the Inferno: the plugin is most useful in hell-hole codebases.

A trail is an ordered walk through one flow in a codebase. Each step is a file, a line range, a title and a note. The plugin opens a trail in its own tabpage: an index panel of step titles on the left, and the code on the right with the current step's range highlighted and its note drawn as virtual lines above it. Steps are re-anchored against the text they point at, so a trail survives edits to the files it describes, and the panel marks steps that drifted or broke.

The repo has three pieces:

- `lua/`, `plugin/`: the Neovim plugin.
- `bin/virgil`: a Python CLI that compiles a JSON draft into a trail, deriving each step's anchor from the file, and reads or drives the reader's position.
- `skills/virgil/`: an agent skill that teaches an agent to author trails with the CLI. The skill carries the CLI as `skills/virgil/virgil`, a relative symlink to `bin/virgil`, so an agent that has the skill has the CLI.

## Install the plugin

Requires Neovim 0.10 or newer. With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "remote-remote/virgil.nvim",
  cmd = { "Virgil", "VirgilQuit", "VirgilNext", "VirgilPrev", "VirgilSteps", "VirgilQuickfix", "VirgilInstall" },
  opts = {},
}
```

For a local checkout, replace the first line with `dir = "~/code/virgil.nvim"`.

`setup()` is optional. The commands are registered from `plugin/` and initialize the plugin on first use. The only option is `root`, which overrides the repo root that trails are listed and watched for (default: the nearest ancestor of the cwd containing `.git`).

## Commands

| Command | Action |
| --- | --- |
| `:Virgil [id]` | Open a trail for the current repo. With several and no id, pick one. |
| `:VirgilNext` | Next step. Opens a trail if none is active. |
| `:VirgilPrev` | Previous step. |
| `:VirgilSteps` | Pick a step in the active trail. |
| `:VirgilQuickfix` | Dump the active trail into the quickfix list. |
| `:VirgilQuit` | Leave the active trail and close its tabpage. |
| `:VirgilInstall {dir} ...` | Link the agent skill into the given skills directories. See [Install the skill and the CLI](#install-the-skill-and-the-cli). |

Inside the index panel: `j` / `k` preview the next or previous step, `<CR>` goes to the step's code, `o` shows it without leaving the panel, `]t` / `[t` step, `q` quits and `Q` dumps to quickfix.

## Suggested keymaps

The plugin maps nothing outside its panel. This is the set it was built with, as lazy.nvim `keys` (`<leader>T` because `<leader>t` was taken by neotest):

```lua
keys = {
  { "]t",         function() require("virgil").next() end,        desc = "Trail: next step" },
  { "[t",         function() require("virgil").prev() end,        desc = "Trail: previous step" },
  { "<leader>To", function() require("virgil").open() end,        desc = "Trail: open" },
  { "<leader>Ts", function() require("virgil").steps() end,       desc = "Trail: pick a step" },
  { "<leader>Tq", function() require("virgil").to_quickfix() end, desc = "Trail: dump to quickfix" },
  { "<leader>Tx", function() require("virgil").quit() end,        desc = "Trail: quit" },
},
```

## Install the skill and the CLI

The plugin links its agent skill into your agents' skills directories. Let lazy.nvim run the installer through `build`, so it reruns whenever the plugin is installed or updated:

```lua
{
  "remote-remote/virgil.nvim",
  build = function()
    require("virgil").install({
      skills_dirs = { "~/.claude/skills", "~/.pi/agent/skills" },
      bin_dir = "~/.local/bin", -- optional
    })
  end,
  -- cmd, opts, keys as above
}
```

`install()` puts a `virgil` symlink in each of `skills_dirs`, pointing at the plugin's `skills/virgil`. With `bin_dir`, it also puts a `virgil` symlink there pointing at `bin/virgil`, for running the CLI yourself. Agents do not need `bin_dir`: the skill runs the CLI from its own folder. `~` is expanded. `:VirgilInstall {dir} ...` does the same for the given skills directories.

The links point into the plugin's install directory, so a plugin update changes the skill and the CLI with it and nothing has to be reinstalled. The installer only creates or repairs links, and prints one line for each:

- `created`: there was nothing at that path.
- `unchanged`: the link was already correct.
- `updated`: the path held a link from an earlier virgil install (its target ends in `virgil.nvim/skills/virgil` or `virgil.nvim/bin/virgil`, or it resolves to this plugin), and it was replaced.
- `refused`: the path holds a real file or directory, or a link to something else, or the destination directory does not exist. Nothing is overwritten and no directory is created.

Each link is relative, computed from the real location of the destination directory. A skills directory is often a symlink into a dotfiles repo, and a relative link committed there resolves from where it really lives. Committing the links in your dotfiles is fine: `lazy-lock.json` pins the plugin commit, so the linked skill and CLI move in lock-step with it.

The CLI is a single Python 3 script with no dependencies. `virgil --help` documents the draft schema and the `create`, `list`, `show`, `cursor` and `rm` commands. `VIRGIL_AUTHOR` sets the author name recorded on created trails.

## Storage

Trails live outside the repository they describe, one JSON file per trail:

```
$XDG_DATA_HOME/virgil/<repo-key>/<id>.json
```

When `XDG_DATA_HOME` is unset or empty, the base is `~/.local/share`. The directory is not under Neovim's `stdpath("data")`, because the CLI writes these files too and `NVIM_APPNAME` would move Neovim's path.

`<repo-key>` is derived from the repo root's realpath, byte for byte the same way in `lua/virgil/store.lua` and `bin/virgil`:

1. Take the last path component of the root and replace every byte outside `A-Z a-z 0-9 . _ -` with `_`. An empty result becomes `root`.
2. Append `-` and the first 12 hex digits of the SHA-256 of the full root path.

For example, `/Users/me/code/virgil.nvim` becomes `virgil.nvim-<12 hex digits>`. The name keeps the directory browsable, and the hash keeps two checkouts with the same name apart. Each worktree is its own root, so it has its own trails. Each trail file also records its `root`, and only trails whose `root` matches are listed.

## Tests

```sh
make test
```

This runs the headless Neovim suite in `tests/`, which also runs the CLI to check that the plugin and CLI agree on the storage path. It needs `nvim` and `python3` on `PATH`, and it writes only under temporary directories.
