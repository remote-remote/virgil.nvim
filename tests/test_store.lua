local store = require("virgil.store")

local function tmpdir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  dir = store.realpath(dir)
  vim.fn.mkdir(store.trails_dir(dir), "p")
  return dir
end

local function write(path, raw)
  local fd = assert(io.open(path, "w"))
  fd:write(raw)
  fd:close()
end

local function read(path)
  local fd = assert(io.open(path, "r"))
  local raw = fd:read("*a")
  fd:close()
  return raw
end

local function trail_json(root, cursor)
  return ([[{
  "version": 1,
  "id": "auth-flow",
  "title": "How a login request becomes a session",
  "root": "%s",
  "author": { "kind": "agent", "name": "claude" },
  "created_at": "2026-09-08T14:02:00Z",
  "cursor": %d,
  "steps": [
    {
      "path": "src/auth.ts",
      "range": [39, 44],
      "anchor": {
        "text": "  const token = mint(user)",
        "symbol": "login"
      },
      "note": "Token is minted here, before verifyMfa runs."
    },
    {
      "path": "src/session.ts",
      "range": [12, 12],
      "anchor": { "text": "export function open(token) {" },
      "note": "And spent here."
    }
  ]
}
]]):format(root, cursor)
end

T.test("store: round-trips a hand-written trail", function()
  local root = tmpdir()
  local path = store.trails_dir(root) .. "/auth.json"
  write(path, trail_json(root, 1))
  local data, err = store.read(path)
  T.eq(err, nil)
  T.eq(data.id, "auth-flow")
  T.eq(data.cursor, 1)
  T.eq(#data.steps, 2)
  T.eq(data.steps[1].range, { 39, 44 })
  T.eq(data.steps[1].anchor.symbol, "login")
  T.eq(data.__file, path)
end)

T.test("store: list only returns trails whose root matches", function()
  local root = tmpdir()
  local dir = store.trails_dir(root)
  write(dir .. "/mine.json", trail_json(root, 0))
  write(dir .. "/theirs.json", trail_json("/somewhere/else", 0))
  write(dir .. "/broken.json", "{ not json")
  local trails, errors = store.list(store.realpath(root))
  T.eq(#trails, 1)
  T.ok(trails[1].__file:match("mine%.json$"))
  T.eq(#errors, 1)
  T.ok(errors[1].path:match("broken%.json$"))
end)

T.test("store: validate rejects malformed trails", function()
  T.ok(store.validate({ version = 2, root = "/r", steps = { {} } }))
  T.ok(store.validate({ version = 1, steps = {} }))
  T.ok(store.validate({ version = 1, root = "/r", steps = {} }))
  T.ok(store.validate({ version = 1, root = "/r", steps = { { path = "a", range = { 1, 2 } } } }))
  T.eq(store.validate({
    version = 1,
    root = "/r",
    steps = { { path = "a", range = { 1, 2 }, note = "n" } },
  }), nil)
end)

T.test("store: cursor write-back changes one number and nothing else", function()
  local root = tmpdir()
  local path = store.trails_dir(root) .. "/auth.json"
  local original = trail_json(root, 1)
  write(path, original)

  local data = assert(store.read(path))
  T.ok(store.write_cursor(data, 0))

  local after = read(path)
  T.eq(after, (original:gsub('"cursor": 1', '"cursor": 0', 1)))
  T.eq(data.cursor, 0)

  local reread = assert(store.read(path))
  T.eq(reread.cursor, 0)
  reread.cursor, data.cursor = nil, nil
  T.eq(reread, data)
end)

T.test("store: patch_cursor refuses to target a cursor mentioned inside a note", function()
  -- the decoy deliberately comes first in the file, so a naive first-match
  -- rewrite would corrupt the note instead of moving the cursor
  local raw = [[{
  "version": 1,
  "id": "t",
  "root": "/r",
  "steps": [
    { "path": "a", "range": [1, 1], "note": "the field \"cursor\": 4 lives on the trail" }
  ],
  "cursor": 0
}]]
  local patched = assert(store.patch_cursor(raw, 3))
  local decoded = assert(vim.json.decode(patched))
  T.eq(decoded.cursor, 3)
  T.eq(decoded.steps[1].note, "the field \"cursor\": 4 lives on the trail")
  T.ok(patched:match('\\"cursor\\": 4'), "the note was left alone")
end)

T.test("store: patch_cursor inserts a missing cursor without reformatting", function()
  local raw = [[{
  "version": 1,
  "id": "t",
  "root": "/r",
  "steps": [
    { "path": "a", "range": [1, 1], "note": "n" }
  ]
}]]
  local patched = assert(store.patch_cursor(raw, 2))
  T.eq(vim.json.decode(patched).cursor, 2)
  T.ok(patched:match('"note": "n"'), "the rest of the file kept its formatting")
end)

T.test("store: abs_path joins against root and passes absolutes through", function()
  local data = { root = "/r" }
  T.eq(store.abs_path(data, { path = "src/a.ts" }), "/r/src/a.ts")
  T.eq(store.abs_path(data, { path = "/elsewhere/a.ts" }), "/elsewhere/a.ts")
end)
