# nvim-breadcrumbs

Neovim breadcrumbs: guided code trails humans and agents build, read, and hand to each other.

A trail is an ordered walk through one flow in a codebase. Each step is a file, a line range, a title and a note. The plugin opens a trail in its own tabpage: an index panel of step titles on the left, and the code on the right with the current step's range highlighted and its note drawn as virtual lines above it. Steps are re-anchored against the text they point at, so a trail survives edits to the files it describes, and the panel marks steps that drifted or broke.

The repo has three pieces:

- `lua/`, `plugin/`: the Neovim plugin.
- `bin/breadcrumbs`: a Python CLI that compiles a JSON draft into a trail, deriving each step's anchor from the file, and reads or drives the reader's position.
- `skills/breadcrumbs/SKILL.md`: an agent skill that teaches an agent to author trails with the CLI. It integrates with the plugin but ships separately from it.

## Install the plugin

Requires Neovim 0.10 or newer. With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "remote-remote/nvim-breadcrumbs",
  cmd = { "Breadcrumbs", "BreadcrumbsQuit", "BreadcrumbsNext", "BreadcrumbsPrev", "BreadcrumbsSteps", "BreadcrumbsQuickfix" },
  opts = {},
}
```

For a local checkout, replace the first line with `dir = "~/code/nvim-breadcrumbs"`.

`setup()` is optional. The commands are registered from `plugin/` and initialize the plugin on first use. The only option is `root`, which overrides the repo root that trails are listed and watched for (default: the nearest ancestor of the cwd containing `.git`).

## Commands

| Command | Action |
| --- | --- |
| `:Breadcrumbs [id]` | Open a trail for the current repo. With several and no id, pick one. |
| `:BreadcrumbsNext` | Next step. Opens a trail if none is active. |
| `:BreadcrumbsPrev` | Previous step. |
| `:BreadcrumbsSteps` | Pick a step in the active trail. |
| `:BreadcrumbsQuickfix` | Dump the active trail into the quickfix list. |
| `:BreadcrumbsQuit` | Leave the active trail and close its tabpage. |

Inside the index panel: `j` / `k` preview the next or previous step, `<CR>` goes to the step's code, `o` shows it without leaving the panel, `]t` / `[t` step, `q` quits and `Q` dumps to quickfix.

## Suggested keymaps

The plugin maps nothing outside its panel. This is the set it was built with, as lazy.nvim `keys` (`<leader>T` because `<leader>t` was taken by neotest):

```lua
keys = {
  { "]t",         function() require("breadcrumbs").next() end,        desc = "Trail: next step" },
  { "[t",         function() require("breadcrumbs").prev() end,        desc = "Trail: previous step" },
  { "<leader>To", function() require("breadcrumbs").open() end,        desc = "Trail: open" },
  { "<leader>Ts", function() require("breadcrumbs").steps() end,       desc = "Trail: pick a step" },
  { "<leader>Tq", function() require("breadcrumbs").to_quickfix() end, desc = "Trail: dump to quickfix" },
  { "<leader>Tx", function() require("breadcrumbs").quit() end,        desc = "Trail: quit" },
},
```

## Install the CLI

The CLI is a single Python 3 script with no dependencies. Put it on your `PATH`, for example:

```sh
ln -s ~/.local/share/nvim/lazy/nvim-breadcrumbs/bin/breadcrumbs ~/.local/bin/breadcrumbs
```

`breadcrumbs --help` documents the draft schema and the `create`, `list`, `show`, `cursor` and `rm` commands. `BREADCRUMBS_AUTHOR` sets the author name recorded on created trails.

## Install the skill

Copy or symlink `skills/breadcrumbs` into your agent's skills directory, for example `~/.claude/skills/breadcrumbs`. The skill expects the CLI on `PATH`.

## Storage

Trails live outside the repository they describe, one JSON file per trail:

```
$XDG_DATA_HOME/breadcrumbs/<repo-key>/<id>.json
```

When `XDG_DATA_HOME` is unset or empty, the base is `~/.local/share`. The directory is not under Neovim's `stdpath("data")`, because the CLI writes these files too and `NVIM_APPNAME` would move Neovim's path.

`<repo-key>` is derived from the repo root's realpath, byte for byte the same way in `lua/breadcrumbs/store.lua` and `bin/breadcrumbs`:

1. Take the last path component of the root and replace every byte outside `A-Z a-z 0-9 . _ -` with `_`. An empty result becomes `root`.
2. Append `-` and the first 12 hex digits of the SHA-256 of the full root path.

For example, `/Users/me/code/nvim-breadcrumbs` becomes `nvim-breadcrumbs-<12 hex digits>`. The name keeps the directory browsable, and the hash keeps two checkouts with the same name apart. Each worktree is its own root, so it has its own trails. Each trail file also records its `root`, and only trails whose `root` matches are listed.

## Tests

```sh
make test
```

This runs the headless Neovim suite in `tests/`, which also runs the CLI to check that the plugin and CLI agree on the storage path. It needs `nvim` and `python3` on `PATH`, and it writes only under temporary directories.
