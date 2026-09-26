local format = require("virgil.format")

local function step(t)
  return vim.tbl_extend("force", { path = "src/auth.ts", note = "", range = { 1, 1 } }, t)
end

T.test("format: an authored title is used verbatim", function()
  T.eq(format.step_title(step({ title = "Token minted", note = "Something else entirely." }), 30),
    "Token minted")
end)

T.test("format: a blank or whitespace title falls through to the note", function()
  T.eq(format.step_title(step({ title = "   ", note = "Token is minted here. Then spent." }), 30),
    "Token is minted here")
end)

T.test("format: the derived title is the first sentence, minus its period", function()
  T.eq(format.step_title(step({ note = "Token is minted here. Everything downstream trusts it." }), 40),
    "Token is minted here")
end)

T.test("format: a dot with no space after it does not end a sentence", function()
  -- notes are full of `vim.env.HERDR_ENV` and `lazy.setup()`
  T.eq(format.first_sentence("vim.env.HERDR_ENV is read at spec-build time. Not later."),
    "vim.env.HERDR_ENV is read at spec-build time")
end)

T.test("format: a note with no sentence-ending punctuation is used whole", function()
  T.eq(format.step_title(step({ note = "minted here and spent later" }), 40),
    "minted here and spent later")
end)

T.test("format: an empty note falls back to the filename", function()
  T.eq(format.step_title(step({ note = "" }), 30), "auth.ts")
  T.eq(format.step_title({ path = "" }, 30), "(step)")
end)

T.test("format: a first sentence that is already too long is cut on a word", function()
  local title = format.step_title(step({
    note = "Token is minted here before verifyMfa ever runs. And then spent.",
  }), 24)
  T.ok(vim.fn.strdisplaywidth(title) <= 24, "fits the panel: " .. title)
  T.eq(title, "Token is minted here…")
end)

T.test("format: truncate_words prefers a word boundary in the back half", function()
  T.eq(format.truncate_words("alpha beta gamma", 12), "alpha beta…")
  -- nothing to fall back to but a severed word
  T.eq(format.truncate_words("supercalifragilistic done", 10), "supercali…")
end)

T.test("format: multibyte titles are cut by display width, not bytes", function()
  local title = format.step_title(step({ title = "réponse à la requête entrante" }), 10)
  T.ok(vim.fn.strdisplaywidth(title) <= 10, title)
end)

T.test("format: an entry shows number, title and path:line", function()
  local e = format.entry(
    { index = 2, step = step({ title = "Token minted", path = "src/auth.ts" }), line = 39, status = "exact" },
    { width = 38, number_width = 2, current = true })
  T.eq(e.top, "▸  3 Token minted")
  T.eq(e.bottom, "     auth.ts:39")
  T.eq(e.badge_col, nil)
  T.eq(e.top:sub(e.title_col + 1), "Token minted")
end)

T.test("format: a drifted entry gets a right-aligned badge", function()
  local e = format.entry(
    { index = 0, step = step({ title = "Checked too late", path = "mfa.ts" }), line = 14, status = "drifted" },
    { width = 30, number_width = 1, current = false })
  T.eq(e.top, "  1 Checked too late")
  T.eq(#e.bottom, 30)
  T.eq(e.bottom:sub(e.badge_col + 1), "drift")
  T.eq(e.badge_hl, "VirgilNoteDrifted")
  T.eq(e.top:sub(1, 1), " ", "only the current step is marked")
end)

T.test("format: the panel column is always the basename", function()
  local e = format.entry({
    index = 0,
    step = step({ title = "t", path = "nvim/.config/nvim/lua/plugins/herdr.lua" }),
    line = 60,
    status = "broken",
  }, { width = 30, number_width = 1, current = false })
  T.eq(e.bottom:sub(1, 15), "    herdr.lua:6")
  T.eq(e.bottom:sub(e.badge_col + 1), "broken")
end)

T.test("format: the header tucks N/M onto the title's last line", function()
  local head = format.header("How a login becomes a session", 2, 7, 24)
  T.eq(head.lines, { " How a login becomes a", " session            3/7" })
  T.eq(head.count_line, 2)
  T.eq(head.lines[2]:sub(head.count_col + 1), "3/7")
end)

T.test("format: a title that fills its last line pushes N/M onto its own", function()
  local head = format.header("exactly-this-wide-word", 0, 1, 24)
  T.eq(#head.lines, 2)
  T.eq(head.lines[2], "                    1/1")
  T.eq(head.lines[2]:sub(head.count_col + 1), "1/1")
end)

T.test("format: the panel maps every entry line back to its step", function()
  local entries = {}
  for i = 1, 3 do
    table.insert(entries, {
      index = i - 1,
      step = step({ title = "step " .. i }),
      line = i * 10,
      status = "exact",
    })
  end
  local built = format.panel({ title = "T", index = 1, total = 3, entries = entries }, 38)

  local seen = {}
  for lnum, index in pairs(built.rows) do
    T.eq(built.lines[lnum] ~= nil, true, "row " .. lnum .. " has a line")
    seen[index] = (seen[index] or 0) + 1
  end
  T.eq(seen, { [0] = 2, [1] = 2, [2] = 2 }, "two lines per step")
  T.eq(built.rows[built.current_row], 1)
  T.ok(built.lines[built.current_row]:match("^▸"), "the current step is marked")
end)

T.test("format: every highlight span stays inside its line", function()
  local built = format.panel({
    title = "A very long trail title that certainly has to wrap more than once here",
    index = 0,
    total = 2,
    entries = {
      { index = 0, step = step({ title = "one" }), line = 1, status = "drifted" },
      { index = 1, step = step({ note = "" }), line = 2, status = "broken" },
    },
  }, 38)
  for _, m in ipairs(built.marks) do
    local line = built.lines[m[1] + 1]
    T.ok(line ~= nil, "mark on row " .. m[1])
    T.ok(m[2] < m[3], "non-empty span")
    T.ok(m[3] <= #line, ("span %d..%d in a %d byte line"):format(m[2], m[3], #line))
  end
end)
