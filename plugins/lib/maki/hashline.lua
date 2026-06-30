local M = {}

M.HASH_LEN = 3
M.HASH_CHARS = "0123456789abcdefghijklmnopqrstuvwxyz"
M.HASH_BASE = 36

local FNV_OFFSET = 0x811C9DC5
local FNV_PRIME = 0x01000193
local MOD = 0x100000000

M.BAD_LINENUMBER = 'linenumber must be "N" or "N-M" with N <= M (1-indexed)'
M.MISSING_LINENUMBER = "edit must set linenumber and hash"
M.HASH_MISMATCH = "hash %s does not match line %d; the file may have changed since you read it — re-read with read"
M.HASH_NOT_IN_RANGE =
  "hash %s does not match any line in range %d-%d; the file may have changed since you read it — re-read with read"
M.OUT_OF_RANGE = "linenumber %d is out of range (file has %d lines)"
M.OVERLAP = "edits overlap; merge them or apply in separate calls"

local function split_lines(s)
  local lines = {}
  local pos = 1
  while pos <= #s do
    local nl = s:find("\n", pos, true)
    if nl then
      local line = s:sub(pos, nl - 1)
      lines[#lines + 1] = line:find("\r$") and line:sub(1, -2) or line
      pos = nl + 1
    else
      local line = s:sub(pos)
      lines[#lines + 1] = line:find("\r$") and line:sub(1, -2) or line
      pos = #s + 1
    end
  end
  return lines
end
M.split_lines = split_lines

function M.hash(line)
  local h = FNV_OFFSET
  for i = 1, #line do
    h = bit32.bxor(h, line:byte(i))
    h = (h * FNV_PRIME) % MOD
  end
  local digits = {}
  for i = M.HASH_LEN, 1, -1 do
    digits[i] = h % M.HASH_BASE
    h = math.floor(h / M.HASH_BASE)
  end
  local out = {}
  for i = 1, M.HASH_LEN do
    out[i] = M.HASH_CHARS:sub(digits[i] + 1, digits[i] + 1)
  end
  return table.concat(out)
end

-- Parse a linenumber spec into a (lo, hi) pair of 1-indexed ints.
-- "42" -> (42, 42); "42-50" -> (42, 50).
local function parse_linenumber(spec)
  if type(spec) ~= "string" then
    return nil
  end
  local lo_s, hi_s = spec:match("^%s*(%d+)%s*-%s*(%d+)%s*$")
  if lo_s then
    local lo, hi = tonumber(lo_s), tonumber(hi_s)
    if lo >= 1 and hi >= lo then
      return lo, hi
    end
    return nil
  end
  local single = spec:match("^%s*(%d+)%s*$")
  if single then
    local n = tonumber(single)
    if n >= 1 then
      return n, n
    end
  end
  return nil
end
M.parse_linenumber = parse_linenumber

local function parse_new_lines(new_string)
  if new_string == nil or new_string == "" then
    return {}
  end
  return split_lines(new_string)
end

-- Returns (a, b, new_lines, err); err is nil on success. All paths return 4
-- values so callers reliably receive err under Luau's arity handling.
local function resolve_op(lines, edit)
  local spec = edit.linenumber
  local hash_str = edit.hash
  if not spec or not hash_str then
    return nil, nil, nil, M.MISSING_LINENUMBER
  end

  local lo, hi = parse_linenumber(spec)
  if not lo then
    return nil, nil, nil, M.BAD_LINENUMBER
  end

  local count = #lines
  if hi > count then
    return nil, nil, nil, string.format(M.OUT_OF_RANGE, hi, count)
  end

  -- The linenumber range only narrows the search; the matched line alone is
  -- replaced, never the whole span.
  local found
  for i = lo, hi do
    if M.hash(lines[i]) == hash_str then
      found = i
      break
    end
  end
  if not found then
    if lo == hi then
      return nil, nil, nil, string.format(M.HASH_MISMATCH, hash_str, lo)
    end
    return nil, nil, nil, string.format(M.HASH_NOT_IN_RANGE, hash_str, lo, hi)
  end

  local new_lines = parse_new_lines(edit.new_string)

  if edit.insert then
    return found + 1, found, new_lines, nil
  end

  return found, found, new_lines, nil
end

function M.apply_edits(content, edits)
  if not edits or #edits == 0 then
    return content, nil
  end

  local trailing_nl = content:sub(-1) == "\n"
  local lines = split_lines(content)

  local ops = {}
  for i, edit in ipairs(edits) do
    local a, b, new_lines, err = resolve_op(lines, edit)
    if not a then
      return nil, err
    end
    ops[#ops + 1] = { a = a, b = b, new_lines = new_lines, seq = i }
  end

  table.sort(ops, function(x, y)
    return x.a > y.a
  end)

  for i = 2, #ops do
    if ops[i].b >= ops[i - 1].a then
      return nil, M.OVERLAP
    end
  end

  for _, op in ipairs(ops) do
    local replacement = {}
    for _, l in ipairs(op.new_lines) do
      replacement[#replacement + 1] = l
    end
    local head = {}
    for j = 1, op.a - 1 do
      head[#head + 1] = lines[j]
    end
    local tail = {}
    for j = op.b + 1, #lines do
      tail[#tail + 1] = lines[j]
    end
    local merged = {}
    for _, l in ipairs(head) do
      merged[#merged + 1] = l
    end
    for _, l in ipairs(replacement) do
      merged[#merged + 1] = l
    end
    for _, l in ipairs(tail) do
      merged[#merged + 1] = l
    end
    lines = merged
  end

  local result = table.concat(lines, "\n")
  if trailing_nl and #lines > 0 then
    result = result .. "\n"
  end
  return result, nil
end

return M
