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
  cmd = {
    "Virgil", "VirgilQuit", "VirgilNext", "VirgilPrev", "VirgilSteps", "VirgilQuickfix", "VirgilInstall",
    "VirgilNew", "VirgilAdd", "VirgilEdit", "VirgilRange", "VirgilRename", "VirgilDelete",
  },
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
| `:VirgilNew [title]` | Start a trail. The current line, or the lines of a visual selection, become step 1, and the step editor opens on it. Asks for a title if none is given. |
| `:VirgilAdd` | Add the current line or selection as a step after the current one, then edit it. With no trail open, pick one or start a new one. |
| `:VirgilAdd!` | Quick pin: add the step with no title or note, without opening the editor. |
| `:VirgilEdit` | Edit the current step's title and note. |
| `:VirgilRange` | Move the current step to the current line or selection. Its anchor is taken from the new first line. |
| `:VirgilRename [title]` | Retitle the active trail. The id and file name stay the same. |
| `:VirgilDelete [id]` | Delete the active trail, or the one named, after a confirmation. This cannot be undone. |
| `:VirgilInstall {dir} ...` | Link the agent skill into the given skills directories. See [Install the skill and the CLI](#install-the-skill-and-the-cli). |

Inside the index panel, keys act on the step under the cursor, or the current step when the cursor is on the header. Each edit is saved at once.

| Key | Action |
| --- | --- |
| `j` / `k` | Preview the next or previous step. |
| `<CR>` | Go to the step's code. |
| `o` | Show the step without leaving the panel. |
| `]t` / `[t` | Next or previous step. |
| `e` | Edit the step's title and note. |
| `r` | Retitle the step, or rename the trail when the cursor is on the header. |
| `a` / `A` | Add a step after this one, or at the end. Pick the lines in the code window, then `<CR>`, or `<Esc>` to cancel. |
| `R` | Re-range the step. Its lines are preselected in the code window. Adjust them, then `<CR>`. |
| `=` | Accept drift: move a drifted step to where its anchor text was found. |
| `dd` | Delete the step and hold it. |
| `p` / `P` | Put the held step after or before this one. |
| `J` / `K` | Move the step down or up. Takes a count. |
| `u` / `<C-r>` | Undo or redo this session's edits. |
| `q` | Quit the trail. |
| `Q` | Dump the trail into the quickfix list. |
| `g?` | List these keys. |

## Writing trails by hand

A step is captured from code: the first line picked is its anchor, the text the plugin looks for when the file changes. Blank lines at either end of a selection are dropped. When the first line also appears elsewhere in the file, the step is scoped to the enclosing function or declaration, and without one the plugin warns that the step can break. A buffer with unsaved changes can still be captured, with a warning that the step anchors to unsaved text.

A step with no note yet is a stub. The panel marks it `stub`, and the code window says "no note yet". Stubs let you pin the stops while reading and write the notes later, or ask an agent to write them.

The step editor is a floating buffer over the code. Line 1 is the step's title, and the note starts on line 3. `:w` saves, `q` closes and asks first if there is unsaved text, and `ZZ` saves and closes. The number at the end of line 1 is the title's width against what the panel shows. The note in the code window follows what you type.

If an agent rewrites the trail while the editor is open, the editor's border says so. `:w` still saves when the step you are editing is unchanged in the new file, wherever it moved to. Otherwise `:w` refuses and keeps your text, and `:w!` overwrites that step.

Every edit is saved to the trail file at once, based on the revision the plugin last read. If an agent wrote the trail in between, the edit is refused, the trail reloads, and you press the key again.

Repairing a trail uses the same keys. For a drifted step, `R` preselects the lines where the step was found, so `R` then `<CR>` re-anchors it there, and `=` does the same in one key when the step was found by its anchor text. A step found only by its symbol has changed inside, so it needs `R`. A broken step has no place in the file, so `R` preselects its stored lines as a starting point.

Undo keeps this session's edits in memory, and each undo or redo is saved like any other edit. A write from outside Neovim, such as an agent's `virgil create`, clears the undo history, because the old snapshots no longer describe the file. If the trail file is deleted while it is open, the panel says "deleted on disk", edits and cursor writes stop, and the trail reloads if the file comes back.

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
  { "<leader>Tn", ":VirgilNew<CR>",       mode = { "n", "x" }, desc = "Trail: new trail from here" },
  { "<leader>Ta", ":VirgilAdd<CR>",       mode = { "n", "x" }, desc = "Trail: add a step here" },
  { "<leader>Tr", ":VirgilRange<CR>",     mode = "x",          desc = "Trail: move the step to these lines" },
  { "<leader>Te", "<cmd>VirgilEdit<CR>",                         desc = "Trail: edit this step" },
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

The CLI is a single Python 3 script with no dependencies. `virgil --help` documents the draft schema and the `create`, `list`, `show`, `cursor` and `rm` commands. `VIRGIL_AUTHOR` sets the name recorded as a trail's author and last editor, by the CLI and the plugin alike (the plugin falls back to `$USER`).

An agent picks up a trail a person started or edited with `virgil show ID --json`, which prints the trail as a draft with its `rev` and each step's anchor. `create --expect-rev REV` writes it back. A step that keeps its `anchor` is checked against the file rather than read again from its line numbers: it stays if its first line still matches, follows the text with a warning if it moved, and is refused if the text is gone. Stubs and untitled steps are written with a warning.

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

## Trail file format and write rules

The plugin and the CLI both write trail files. They follow the rules below, and `tests/test_contract.lua` runs both implementations against each other to hold them to it.

A trail file is a JSON object with these fields, in this order:

| Field | Type | Meaning |
| --- | --- | --- |
| `version` | `1` | Format version. |
| `id` | string | The file name without `.json`. Letters, digits, `.`, `_` and `-`. |
| `title` | string | The panel header. Required, not blank. |
| `root` | string | Realpath of the repo root the step paths are relative to. |
| `author` | `{kind, name}` | Who created the trail. `kind` is `human` or `agent`. |
| `created_at` | string | UTC, `YYYY-MM-DDTHH:MM:SSZ`. |
| `updated_by` | `{kind, name}` | Who made the last content write. |
| `updated_at` | string | When the last content write happened. |
| `rev` | integer | Revision counter. A file without one is at rev 0. |
| `cursor` | integer | The reader's step, 0-based. |
| `steps` | list | At least one step. |

Each step has `path` (relative to `root`), `title` (may be empty), `range` (`[start, end]`, 1-based and inclusive), `anchor` (`{text, symbol}`, with `symbol` optional) and `note` (may be empty). A step with no note yet is a stub: a stop someone pinned and has not written up.

Write rules:

1. `anchor.text` is the first line of the range, read from the file or the editor buffer when the location is captured. It must not be blank. A step's anchor changes only when its location is captured again. Every other edit carries the anchor through untouched, because deriving it again from stored line numbers points a step whose file has changed at the wrong line.
2. A content write is any change other than `cursor`. It must be based on the current `rev`, and it writes `rev + 1`, `updated_by` and `updated_at`. A writer that finds a different `rev` on disk refuses and re-reads.
3. A `cursor` write does not change `rev`, so a reader stepping through a trail never blocks an agent's revision.
4. `created_at` and `author` are kept on every rewrite. Fields a writer does not know are kept too.
5. Every write goes to a temporary file next to the trail and is renamed over it, so no reader ever sees half a file.
6. Files are written as JSON with two-space indentation, fields in the order above, unknown fields after the known ones sorted by name, and non-ASCII text written as is.

The CLI refuses to rewrite a trail whose last content write was by a `human` unless it is given the current revision with `--expect-rev`. The plugin reads files more loosely than it writes them, so a hand-written trail with no `rev`, `anchor` or step titles still opens.

## Tests

```sh
make test
```

This runs the headless Neovim suite in `tests/`, which also runs the CLI to check that the plugin and CLI agree on the storage path. It needs `nvim` and `python3` on `PATH`, and it writes only under temporary directories.
