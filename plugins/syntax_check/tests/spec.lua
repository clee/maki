local Proposed = require("proposed")
local Checkers = require("checkers")
local th = require("maki.test_helpers")

local case = th.case
local eq = th.eq
local has = th.has

local DIR = "/tmp/maki_syntax_check_spec"
local seq = 0

local function tmp(ext)
  seq = seq + 1
  return DIR .. "/" .. seq .. "." .. ext
end

local function write(path, content)
  maki.fs.write(path, content)
  return path
end

-- A .ck checker that fails only on content carrying SYNTAX_BAD, so no case
-- depends on a language toolchain. sh -c 'script' sh <path> binds $1 = path.
local function install_ck_checker()
  Checkers.checkers.ck = {
    exe = "sh",
    args = { "-c", 'if grep -q SYNTAX_BAD "$1"; then echo has-bad >&2; exit 3; else exit 0; fi', "sh" },
    probe = "clean\n",
  }
  Checkers.reset()
end

case("setup_tmp_dir", function()
  maki.fs.rm(DIR, { recursive = true, force = true })
  maki.fs.mkdir(DIR, { parents = true })
  install_ck_checker()
end)

case("write_whole_file_is_judged_directly", function()
  eq(Proposed.reject("write", { path = tmp("ck"), content = "clean\n" }), nil)
  has(Proposed.reject("write", { path = tmp("ck"), content = "SYNTAX_BAD\n" }), "sh reports")
end)

case("write_append_is_judged_as_existing_plus_fragment", function()
  local path = write(tmp("ck"), "start\n")
  eq(Proposed.reject("write", { path = path, content = "more\n", append = true }), nil)
  has(Proposed.reject("write", { path = path, content = "SYNTAX_BAD\n", append = true }), "was not written")
end)

case("edit_is_judged_on_the_merged_file", function()
  local path = write(tmp("ck"), "foo\n")
  eq(Proposed.reject("edit", { path = path, old_string = "foo", new_string = "bar" }), nil)
  has(Proposed.reject("edit", { path = path, old_string = "foo", new_string = "SYNTAX_BAD" }), "sh reports")
end)

case("multiedit_folds_each_edit_in_order", function()
  local path = write(tmp("ck"), "a\nb\n")
  eq(
    Proposed.reject("multiedit", {
      path = path,
      edits = { { old_string = "a", new_string = "x" }, { old_string = "b", new_string = "y" } },
    }),
    nil
  )
  has(
    Proposed.reject("multiedit", {
      path = path,
      edits = { { old_string = "a", new_string = "x" }, { old_string = "b", new_string = "SYNTAX_BAD" } },
    }),
    "sh reports"
  )
end)

case("edit_lines_and_insert_lines_are_judged_on_the_splice", function()
  local path = write(tmp("ck"), "l1\nl2\nl3\n")
  has(Proposed.reject("edit_lines", { path = path, start = 2, ["end"] = 2, new_string = "SYNTAX_BAD" }), "sh reports")
  eq(Proposed.reject("edit_lines", { path = path, start = 2, ["end"] = 2, new_string = "ok" }), nil)
  has(Proposed.reject("insert_lines", { path = path, line = 1, new_string = "SYNTAX_BAD" }), "sh reports")
end)

case("an_uncheckable_call_proceeds", function()
  -- Unknown ext, a tool with no derivation, and a missing file all say nothing,
  -- leaving the tool to fail (or succeed) on its own.
  eq(Proposed.reject("write", { path = tmp("unknownext"), content = "SYNTAX_BAD" }), nil)
  eq(Proposed.reject("bash", { path = tmp("ck"), content = "SYNTAX_BAD" }), nil)
  eq(Proposed.reject("edit", { path = DIR .. "/gone.ck", old_string = "x", new_string = "y" }), nil)
end)

case("rust_is_checked_in_process_by_tree_sitter", function()
  eq(Proposed.reject("write", { path = tmp("rs"), content = "fn main() { let x = 1u8; let _ = x; }\n" }), nil)
  has(Proposed.reject("write", { path = tmp("rs"), content = "fn main() { let x = ; }\n" }), "tree-sitter rust")
end)

case("rust_mod_declarations_are_not_resolved", function()
  -- The isolated-parse property that ruled rustfmt out: a `mod x;` child that
  -- does not exist must not make a valid file look broken.
  eq(Proposed.reject("write", { path = tmp("rs"), content = "pub mod some_absent_child;\npub struct S;\n" }), nil)
end)

local MATRIX = {
  { ext = "rs", valid = "fn main() {}\n", invalid = "fn main( {\n" },
  { ext = "lua", valid = "local a = 1\n", invalid = "local a = = 1\n" },
  { ext = "py", valid = "x = 1\n", invalid = "def f(:\n" },
  { ext = "sh", valid = 'x="1"\n', invalid = 'echo "$(unclosed\n' },
  { ext = "json", valid = '{"a": 1}\n', invalid = '{"a": ,}\n' },
  { ext = "toml", valid = "a = 1\n", invalid = "[bad\n" },
  { ext = "yaml", valid = "a: 1\n", invalid = "a: [1, 2\n" },
  { ext = "js", valid = "const x = 1;\n", invalid = "const = ;\n" },
  { ext = "go", valid = "package p\n", invalid = "package p\nfunc f( {\n" },
}

-- Every real checker, driven with valid and mutated-invalid source. Skips a
-- language whose tool AND tree-sitter fallback are both absent, so the matrix
-- stays deterministic on any box while hard-asserting the ones that are present.
case("every_registered_language_accepts_valid_and_rejects_invalid", function()
  local checked = 0
  for _, row in ipairs(MATRIX) do
    if Checkers.usable(row.ext) then
      eq(Checkers.check(tmp(row.ext), row.valid), nil, row.ext .. " valid must pass")
      assert(Checkers.check(tmp(row.ext), row.invalid), row.ext .. " invalid must be rejected")
      checked = checked + 1
    end
  end
  assert(checked >= 1, "expected at least the rs checker to be usable")
end)

-- The tree-sitter fallback, exercised directly for every language that has one,
-- so the no-tool path is proven even where the authoritative tool is installed.
case("tree_sitter_fallback_catches_invalid_for_each_grammar", function()
  local covered = 0
  for _, row in ipairs(MATRIX) do
    local grammar = Checkers.checkers[row.ext] and Checkers.checkers[row.ext].ts
    if grammar then
      eq(Checkers.check_grammar(grammar, row.valid), nil, grammar .. " valid must parse")
      local verdict = Checkers.check_grammar(grammar, row.invalid)
      assert(verdict and verdict ~= "unavailable", grammar .. " invalid must be rejected")
      covered = covered + 1
    end
  end
  -- Grammars are embedded, so every matrix row has a fallback to prove.
  eq(covered, #MATRIX, "every language has a tree-sitter grammar")
end)

case("teardown", function()
  maki.fs.rm(DIR, { recursive = true, force = true })
end)

th.report()
