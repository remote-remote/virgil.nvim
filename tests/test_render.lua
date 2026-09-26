local render = require("breadcrumbs.render")

T.test("render: a mid-file step hangs its note above the range", function()
  local row, above = render.note_anchor(10, 14)
  T.eq(row, 9)
  T.eq(above, true)
end)

T.test("render: a step starting on line 1 hangs its note below the range", function()
  local row, above = render.note_anchor(1, 7)
  T.eq(row, 6)
  T.eq(above, false)
end)

T.test("render: a single-line step on line 1 still lands on that line", function()
  local row, above = render.note_anchor(1, 1)
  T.eq(row, 0)
  T.eq(above, false)
end)
