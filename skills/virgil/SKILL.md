---
name: virgil
description: Author a Virgil trail, a guided code tour the reader steps through in their editor. Use when asked to tour or walk through how something works, or when the answer would otherwise be prose full of file:line references the reader has to chase by hand.
---

# Virgil trails

A trail is an ordered walk through one flow. Each step is a file, a line range, a title and a note. The `virgil` CLI compiles it to `$XDG_DATA_HOME/virgil/<repo-key>/<id>.json` (falling back to `~/.local/share/virgil/`), outside the repo it describes; the virgil nvim plugin watches that directory and renders it as a tabpage, titles in a 38-column index panel and each note as virtual lines above the code itself. The reader opens it with `:Virgil` and steps with `:VirgilNext` / `:VirgilPrev`.

Reach for one when the answer spans several files and the reader will want to be *in* those files: how a request becomes a session, how boot actually orders itself, what the change you just made touched. A question answered by one file, or answered yes/no, is prose.

## The reader has the file open

This is the whole constraint. They can see the line, the lines around it, the imports above it. A note that says what the line says spends their attention on a window they are already looking at.

So aim every note at what is **not** on the screen. A fact is **load-bearing** when knowing it changes what the reader does next: where they would add code, what they would suspect when it breaks, which refactor they now know to avoid, what has to already be true for this line to work.

| The line | Reading it back | Load-bearing |
| --- | --- | --- |
| `require("keymaps")` | "Loads the keymaps module." | "`mapleader` is read when a mapping is *created*, not when the key is pressed, so any leader mapping defined before this line silently lands on `\`." |
| `import = "plugins"` | "Imports the plugins directory." | "Import is not recursive. A spec file dropped in a deeper subdirectory is silently ignored, which is why `lua/plugins/lsp` needs its own entry." |
| `cond = vim.env.HERDR_ENV == '1'` | "Only loads inside herdr." | "`cond` makes the plugin *absent*, not deferred: lazy drops the plugin, its config and its keymaps, and `:Lazy load` will not rescue that session." |

The right-hand column is what a trail is for. Everything else is available by pressing `gd`.

## Every step earns its place

The failure mode is the step that is there so the walk feels continuous: it reads fine, it is accurate, and it teaches nothing. **Filler.** You will resist cutting it because the trail feels incomplete without it. It isn't. The panel shows the reader exactly where they are in the flow, so a jump does not lose them.

Write the note first, then ask what it costs the reader to skip the step. If the answer is nothing, cut it.

The count falls out of how many load-bearing facts the flow actually has, not out of a target. Under five steps usually means the trail is just the shape of the call chain, which the reader could have got from a grep. Over twelve means filler crept in.

## Titles

Required: `virgil` refuses a step without one, because the alternative is the panel guessing from the note's first sentence.

A title is the **claim the step makes**, not the name of the code it points at. "Leader before every mapping", not "keymaps.lua". Keep it under about 34 columns or the panel truncates it. Read the titles on their own when you are done: they should hold together as an argument, which is what the reader skims when they come back to the trail a week later.

## Ranges

- **Start on a distinctive line.** The first line of the range is the anchor nvim re-anchors against once the file is edited, so `end`, `return {` and `})` are weak keys. When the natural boundary is one of those, pass `symbol` to scope the search to the enclosing function or table rather than moving the boundary: the range should break where the flow breaks.
- Keep the range to what the note is about, usually well under twenty lines. The reader sees the surrounding code regardless.
- Several steps in one file is normal. Consecutive steps in one file is normal.

## Writing it

Trace the flow in the actual files first. A trail assembled from what the names imply is worse than prose, because it looks authoritative and puts the reader's cursor on the wrong line.

Then pipe a draft in. Use a quoted heredoc so backticks and `$` inside notes survive the shell:

```sh
virgil create <<'EOF'
{"title": "How a login request becomes a session", "steps": [
  {"path": "src/auth/login.ts", "range": [39, 52],
   "title": "Token minted here",
   "note": "The signing key is read once at module load, so rotating it needs a restart."}
]}
EOF
```

`virgil --help` has the full draft schema and the other commands. Anchors are derived from the files, never written by hand.

Fix everything it warns about, or tell the reader why you left it. Re-running `create` with the same id rewrites the trail in place and the reader's open tabpage reloads, so revising is cheap.

Finally, hand over the title and `:Virgil <id>` and stop. Summarising the trail back in the terminal rebuilds the wall of `file:line` prose the trail exists to replace. `virgil cursor <id>` reports which step they reached, if you need to know whether it landed.
