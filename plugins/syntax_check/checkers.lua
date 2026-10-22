-- Syntax checkers: run proposed content and answer whether it parses, so a
-- broken file is refused before it is written. Two engines:
--
--   * tree-sitter (embedded in maki, ~34 grammars): an in-process single-string
--     parse via root:has_error(). No subprocess, no external tool, deterministic.
--     Used for Rust and as the cheap fallback — but it only reports a position.
--   * a language's own parse-only tool, when one exists on the box (luac,
--     python -m ast, ...): richer error text, but needs the binary.
--
-- For either engine, a checker that cannot be asked (missing tool, unknown
-- language) answers nothing and the write proceeds. A toolchain gap must never
-- block valid work — only genuinely broken content is rejected.

local M = {}

local CHECK_TIMEOUT_MS = 10000
local ERROR_MAX_BYTES = 8192
local TMP_TEMPLATE = "/tmp/maki-syntax-check-%d-%d.%s"

-- ext (lowercase) -> { ts?, exe, args, probe }.
--   ts:    embedded tree-sitter grammar name. The authoritative tool is tried
--          first; the grammar is the fallback when the tool is absent, and the
--          sole engine where no stable dependency-free tool exists (Rust).
--   exe/args/probe: a parse-only subprocess. `args` precede the temp file path;
--          `probe` is valid source that must parse before the tool is trusted.
M.checkers = {
  -- No external Rust parse-only checker is both stable and dependency-free:
  -- `rustfmt` can't resolve `mod x;` children and `rustc -Zparse-only` is
  -- nightly. tree-sitter parses the single file, exactly what a gate needs.
  rs = { ts = "rust" },
  lua = {
    exe = "luac",
    args = { "-p" },
    probe = "local a = 1 ~= 2\nif a then return 1 end\n",
    ts = "lua",
  },
  py = {
    exe = "python3",
    args = { "-c", "import ast,sys; ast.parse(open(sys.argv[1],encoding='utf-8').read(), sys.argv[1])" },
    probe = "x: int = 1\nprint((y := 3))\n",
    ts = "python",
  },
  sh = { exe = "bash", args = { "-n" }, probe = 'x="${y:-1}"\n', ts = "bash" },
  json = { exe = "jq", args = { "empty" }, probe = '{"a": [1, 2]}\n', ts = "json" },
  toml = {
    exe = "python3",
    args = { "-c", "import tomllib,sys; tomllib.load(open(sys.argv[1],'rb'))" },
    probe = "a = [1, 2]\n",
    ts = "toml",
  },
  yaml = {
    exe = "python3",
    args = { "-c", "import yaml,sys; yaml.safe_load(open(sys.argv[1],encoding='utf-8'))" },
    probe = "a: [1, 2]\n",
    ts = "yaml",
  },
  js = { exe = "node", args = { "--check" }, probe = "const x = null?.a ?? 1;\n", ts = "javascript" },
  go = { exe = "gofmt", args = { "-e", "-l" }, probe = "package p\n\nfunc f() { _ = 1 }\n", ts = "go" },
}
M.checkers.bash = M.checkers.sh
M.checkers.yml = M.checkers.yaml
M.checkers.mjs = M.checkers.js
M.checkers.cjs = M.checkers.js

-- ext -> true (subprocess probe passed) / false (untrusted). Filled on first
-- subprocess use, cleared by M.reset() when the checker table changes.
local trust = {}
local tmp_seq = 0

function M.reset()
  trust = {}
end

local function tmp_path(ext)
  tmp_seq = tmp_seq + 1
  return string.format(TMP_TEMPLATE, os.time(), tmp_seq, ext)
end

local function clip(text)
  if #text <= ERROR_MAX_BYTES then
    return text
  end
  return text:sub(1, ERROR_MAX_BYTES) .. ("\n… clipped, %d more bytes"):format(#text - ERROR_MAX_BYTES)
end

-- Descend to the first node the grammar flagged as ERROR or MISSING, to point
-- at where the parse broke rather than just "somewhere".
local function error_site(root)
  local node = root
  for _ = 1, 512 do
    if node:type() == "ERROR" or node:missing() then
      return node
    end
    local next
    for _, child in ipairs(node:children()) do
      if child:has_error() then
        next = child
        break
      end
    end
    if not next then
      return node
    end
    node = next
  end
  return node
end

local function tree_sitter_error(root)
  local node = error_site(root)
  local row, col = node:start()
  local what
  if node:missing() then
    what = "missing " .. node:type()
  elseif node:type() == "ERROR" then
    what = "syntax error"
  else
    what = "unexpected " .. node:type()
  end
  return ("%s at %d:%d"):format(what, row + 1, col + 1)
end

-- true: parses clean. false + message: rejected. nil: could not be asked.
local function run_tree_sitter(grammar, content)
  local parser, err = maki.treesitter.get_string_parser(content, grammar)
  if not parser then
    return nil, nil, err
  end
  local trees = parser:parse()
  local root = trees[1] and trees[1]:root()
  if not root then
    return nil, nil, "no tree"
  end
  if root:has_error() then
    return false, tree_sitter_error(root), nil
  end
  return true, nil, nil
end

-- true: the tool passes the content. false + output: it rejects it. nil: the
-- tool could not be asked (missing, unspawnable, timed out).
local function run_tool(checker, ext, content)
  local path = tmp_path(ext)
  local _, write_err = maki.fs.write(path, content)
  if write_err then
    return nil, nil
  end
  local argv = { checker.exe }
  for _, arg in ipairs(checker.args) do
    argv[#argv + 1] = arg
  end
  argv[#argv + 1] = path
  -- Plugin scope: a slot layer runs outside any tool task, and every parser
  -- here exits on its own in milliseconds.
  local id, start_err = maki.fn.jobstart(argv, { scope = "plugin" })
  if not id then
    maki.log.warn(("syntax_check: %s unavailable: %s"):format(checker.exe, start_err))
    maki.fs.rm(path, { force = true })
    return nil, nil
  end
  local result, wait_err = maki.fn.jobwait(id, CHECK_TIMEOUT_MS)
  maki.fs.rm(path, { force = true })
  if not result then
    maki.fn.jobstop(id)
    maki.log.warn(("syntax_check: %s wait failed: %s"):format(checker.exe, wait_err))
    return nil, nil
  end
  if result.exit_code == 0 then
    return true, nil
  end
  local output = result.stderr
  if output == "" then
    output = result.stdout
  end
  return false, output
end

-- Probe once: a known-good snippet must parse before any real edit is judged,
-- so a missing/too-old tool disables its ext (fail-open) instead of rejecting
-- valid code. Returns true to trust the tool.
local function probe(checker, key)
  local ok = run_tool(checker, key, checker.probe)
  trust[key] = ok == true
  if not trust[key] then
    maki.log.warn(("syntax_check: probe failed, %s disabled for .%s"):format(checker.exe, key))
  end
  return trust[key]
end

-- Tree-sitter verdict alone: nil to proceed, a message to reject, "unavailable"
-- if the grammar is not embedded. Public so the spec can prove each fallback
-- works even on a box that has the authoritative tool installed.
function M.check_grammar(grammar, content)
  local ok, why = run_tree_sitter(grammar, (content:gsub("\r\n", "\n")))
  if ok == true then
    return nil
  end
  if ok == false then
    return ("tree-sitter %s reports:\n%s"):format(grammar, clip(why or ""))
  end
  return "unavailable"
end

-- Whether an ext has a checker that can be trusted right now: tree-sitter
-- grammars are always available; a subprocess is probed (once) and trusted only
-- if its known-good snippet parses. Lets callers (and the spec) tell "no
-- checker here" apart from "content parses", so absent tools are skipped, not
-- asserted against.
function M.usable(ext)
  local key = ext and ext:lower()
  local checker = key and M.checkers[key]
  if not checker then
    return false
  end
  if checker.ts then
    return true
  end
  if trust[key] == nil then
    probe(checker, key)
  end
  return trust[key] == true
end

-- Returns nil when the write may proceed (no checker, every engine unavailable,
-- or content parses) or the rejection text naming the engine that rejected.
function M.check(path, content)
  local ext = maki.fs.ext(path)
  local key = ext and ext:lower()
  local checker = key and M.checkers[key]
  if not checker then
    return nil
  end
  -- Both engines see LF only, so a CRLF file is not judged on its endings.
  content = content:gsub("\r\n", "\n")

  -- The authoritative tool first: its parse is exact and its error text is
  -- prose. A trusted tool that cannot be asked this once (timeout) is no reason
  -- to block, so fall through to the grammar rather than fail closed.
  if checker.exe and trust[key] ~= false then
    if trust[key] == nil then
      probe(checker, key)
    end
    if trust[key] then
      local ok, why = run_tool(checker, key, content)
      if ok == true then
        return nil
      end
      if ok == false then
        return ("%s reports:\n%s"):format(checker.exe, clip(why or ""))
      end
    end
  end

  -- tree-sitter: primary for `ts`-only (Rust), the fallback when the tool is
  -- absent or a trusted run could not complete.
  if checker.ts then
    local verdict = M.check_grammar(checker.ts, content)
    if verdict and verdict ~= "unavailable" then
      return verdict
    end
  end
  return nil
end

return M
