-- Derives the content an edit-family call is about to write, so the syntax
-- checker judges what would actually land on disk. A slot layer only sees the
-- tool input, not the merged file, so each tool's transform is reproduced here
-- against the current file: `maki.fuzzy_replace` is the exact one edit and
-- multiedit run (the shared module), and the line splices mirror the edit
-- plugin's helpers. Nothing here writes; it answers whether the merge parses.

local Checkers = require("checkers")
local fuzzy_replace = require("maki.fuzzy_replace")

local M = {}

local function read_lf(path)
  local content, err = maki.fs.read(maki.fs.abspath(path))
  if not content then
    return nil
  end
  return content:gsub("\r\n", "\n")
end

-- Mirrors plugins/edit/edit_helpers.lua so edit_lines/insert_lines are judged
-- on the same bytes the tool would write. Both operate on LF text; the checker
-- normalizes line endings anyway, so a CRLF file's endings never reach it.
local function split_lines(s)
  if s:sub(-1) == "\n" then
    s = s:sub(1, -2)
  end
  return maki.split(s, "\n")
end

local function replace_lines(content, start_line, end_line, new_string)
  local lines = split_lines(content)
  local inserting = end_line == nil
  if start_line < 1 or start_line > #lines + (inserting and 1 or 0) then
    return nil
  end
  if not inserting and (end_line < start_line or end_line > #lines) then
    return nil
  end
  local skip_to = inserting and start_line - 1 or end_line
  local result = {}
  for i = 1, start_line - 1 do
    result[#result + 1] = lines[i]
  end
  if new_string ~= "" or inserting then
    for _, line in ipairs(split_lines(new_string)) do
      result[#result + 1] = line
    end
  end
  for i = skip_to + 1, #lines do
    result[#result + 1] = lines[i]
  end
  local joined = table.concat(result, "\n")
  return content:sub(-1) == "\n" and joined .. "\n" or joined
end

-- tool name -> function(value) -> the content the call would write, or nil
-- when it cannot be derived (the tool fails on its own, so the checker says naught).
local DERIVE = {
  write = function(value)
    if value.append then
      return (read_lf(value.path) or "") .. value.content
    end
    return value.content
  end,
  edit = function(value)
    local content = read_lf(value.path)
    if not content then
      return nil
    end
    return fuzzy_replace.replace(content, value.old_string, value.new_string, value.replace_all or false)
  end,
  multiedit = function(value)
    local content = read_lf(value.path)
    if not content then
      return nil
    end
    for _, edit in ipairs(value.edits or {}) do
      content = fuzzy_replace.replace(content, edit.old_string, edit.new_string, edit.replace_all or false)
      if not content then
        return nil
      end
    end
    return content
  end,
  edit_lines = function(value)
    local content = read_lf(value.path)
    if not content then
      return nil
    end
    return replace_lines(content, value.start, value["end"], value.new_string)
  end,
  insert_lines = function(value)
    local content = read_lf(value.path)
    if not content then
      return nil
    end
    return replace_lines(content, value.line + 1, nil, value.new_string)
  end,
}

-- nil: the call may proceed. string: reject it, with the checker's reason.
function M.reject(tool, value)
  local derive = DERIVE[tool]
  if not derive or type(value) ~= "table" or not value.path then
    return nil
  end
  local content = derive(value)
  if not content then
    return nil
  end
  local reason = Checkers.check(maki.fs.abspath(value.path), content)
  if not reason then
    return nil
  end
  return ("syntax error: %s was not written.\n%s"):format(value.path, reason)
end

return M
