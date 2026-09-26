local trail = require("virgil.trail")

local function fixture(count, cursor)
  local steps = {}
  for i = 1, count do
    table.insert(steps, { path = "a.lua", range = { i, i }, note = "step " .. i })
  end
  return { version = 1, id = "t", root = "/r", cursor = cursor, steps = steps }
end

T.test("trail: load starts at the on-disk cursor", function()
  trail.load(fixture(5, 2))
  T.eq(trail.index(), 2)
  T.eq(trail.current().note, "step 3")
  T.eq(trail.count(), 5)
end)

T.test("trail: a missing or out-of-band cursor is clamped, not an error", function()
  trail.load(fixture(3, nil))
  T.eq(trail.index(), 0)
  trail.load(fixture(3, 99))
  T.eq(trail.index(), 2)
  trail.load(fixture(3, -4))
  T.eq(trail.index(), 0)
end)

T.test("trail: prev at step 0 does not move and reports it", function()
  trail.load(fixture(3, 0))
  T.eq(trail.prev(), false)
  T.eq(trail.index(), 0)
  T.ok(trail.at_start())
end)

T.test("trail: next at the last step does not move and reports it", function()
  trail.load(fixture(3, 2))
  T.eq(trail.next(), false)
  T.eq(trail.index(), 2)
  T.ok(trail.at_end())
end)

T.test("trail: next and prev walk the whole trail", function()
  trail.load(fixture(4, 0))
  local seen = { trail.current().note }
  while trail.next() do table.insert(seen, trail.current().note) end
  T.eq(seen, { "step 1", "step 2", "step 3", "step 4" })
  while trail.prev() do end
  T.eq(trail.index(), 0)
end)

T.test("trail: jump clamps and reports whether it moved", function()
  trail.load(fixture(4, 1))
  T.eq(trail.jump(1), false)
  T.eq(trail.jump(3), true)
  T.eq(trail.jump(50), false)
  T.eq(trail.index(), 3)
  T.eq(trail.jump(-50), true)
  T.eq(trail.index(), 0)
end)

T.test("trail: a single-step trail is at both ends at once", function()
  trail.load(fixture(1, 0))
  T.ok(trail.at_start())
  T.ok(trail.at_end())
  T.eq(trail.next(), false)
  T.eq(trail.prev(), false)
end)

T.test("trail: unload leaves nothing active", function()
  trail.load(fixture(3, 0))
  trail.unload()
  T.eq(trail.is_active(), false)
  T.eq(trail.count(), 0)
  T.eq(trail.current(), nil)
  T.eq(trail.next(), false)
end)
