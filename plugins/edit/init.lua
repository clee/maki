local shorten_path = require("maki.shorten_path")
local ToolView = require("maki.tool_view")
local fuzzy_replace = require("maki.fuzzy_replace")
local hashline = require("maki.hashline")

local EDIT_DESCRIPTION = [[Replace an exact string match in a file.

- The old_string must appear exactly once unless replace_all is true.
- Read the file first to get exact content.
- When copying text from read output, do NOT include the line number prefix (e.g. `42: `) - only the content after it.
- Prefer this over write for targeted changes - it uses far fewer tokens.
- Use replace_all for renaming across a file.
]]

local MULTIEDIT_DESCRIPTION = [[Make multiple find-and-replace edits to a single file atomically.
Prefer this over edit when making multiple changes to the same file.

- Read the file first to get exact content.
- old_string must match the file contents exactly, including all whitespace and indentation.
- Each edit must match exactly once unless replace_all is true. Use replace_all for renaming across a file.
- Edits are applied in sequence - each operates on the result of the previous.
- If any edit fails, none are written.
- Ensure earlier edits don't affect text that later edits need to find.
]]

local HASHEDIT_DESCRIPTION = [[Edit a file by line number, verified against a short content hash.

- Read (or grep) the file first: every line comes back tagged `NR:HASH|content`.
- Each edit pins a line by number, paired with the line's HASH for verification.
- If the file changed since you read it, the hash won't match and the edit is rejected before any change is made — re-read.
- Each edit is one of:
  - replace a line: set linenumber + hash + new_string.
  - delete a line: set linenumber + hash (omit or empty new_string).
  - insert after a line: set linenumber + hash + new_string + insert=true.
- linenumber is "N" for a single line, or "N-M" to search an inclusive range; the hash must match the one line to edit, and only that line is affected.
- Edits apply bottom-to-top and must not overlap. If any edit fails, none are written.
]]

local function edit_header(input)
  local buf = maki.ui.buf()
  buf:line({ { shorten_path(input.path or ""), "path" } })
  return buf
end

local function edit_restore(_input, output, _is_error, _ctx)
  return ToolView.restore(output, { max_lines = 0 })
end

local function apply_edit(path, ctx, transform)
  path = maki.fs.abspath(path)

  local ok, err = ctx:check_before_edit(path)
  if not ok then
    return nil, err
  end

  local before, read_err = maki.fs.read(path)
  if read_err then
    return nil, "read error: " .. tostring(read_err)
  end

  local after, transform_err = transform(before)
  if transform_err then
    return nil, transform_err
  end

  local _, write_err = maki.fs.write(path, after)
  if write_err then
    return nil, "write error: " .. tostring(write_err)
  end

  ctx:record_read(path)

  return {
    path = path,
    before = before,
    after = after,
  }
end

local function diff_result(edit_result, summary)
  return {
    llm_output = summary,
    diff_path = edit_result.path,
    diff_before = edit_result.before,
    diff_after = edit_result.after,
    written_path = edit_result.path,
  }
end

maki.api.register_tool({
  name = "edit",
  kind = "edit",
  mutable_path = "path",
  permission_scope = "path",
  audiences = { "main", "general_sub", "interpreter" },
  description = EDIT_DESCRIPTION,

  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Absolute path to the file",
        required = true,
        alias = "file_path",
      },
      old_string = {
        type = "string",
        description = "Exact string to find (must match uniquely unless replace_all is true)",
        required = true,
      },
      new_string = {
        type = "string",
        description = "Replacement string",
        required = true,
      },
      replace_all = {
        type = "boolean",
        description = "Replace all occurrences (default false)",
      },
    },
  },

  header = edit_header,
  restore = edit_restore,

  handler = function(input, ctx)
    local result, err = apply_edit(input.path, ctx, function(content)
      return fuzzy_replace.replace(content, input.old_string, input.new_string, input.replace_all or false)
    end)
    if not result then
      return { llm_output = err, is_error = true }
    end

    return diff_result(result, "edited " .. shorten_path(result.path))
  end,
})

maki.api.register_tool({
  name = "multiedit",
  kind = "edit",
  mutable_path = "path",
  permission_scope = "path",
  start_annotation = "edits",
  audiences = { "main", "general_sub", "interpreter" },
  description = MULTIEDIT_DESCRIPTION,

  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Absolute path to the file",
        required = true,
        alias = "file_path",
      },
      edits = {
        type = "array",
        description = "Array of edit operations to apply sequentially",
        required = true,
        items = {
          type = "object",
          properties = {
            old_string = {
              type = "string",
              description = "Exact string to find",
              required = true,
            },
            new_string = {
              type = "string",
              description = "Replacement string",
              required = true,
            },
            replace_all = {
              type = "boolean",
              description = "Replace all occurrences (default false)",
            },
          },
        },
      },
    },
  },

  header = edit_header,
  restore = edit_restore,

  handler = function(input, ctx)
    local edits = input.edits
    if #edits == 0 then
      return { llm_output = "provide at least one edit", is_error = true }
    end

    local result, err = apply_edit(input.path, ctx, function(content)
      for i, edit in ipairs(edits) do
        local replaced, replace_err =
          fuzzy_replace.replace(content, edit.old_string, edit.new_string, edit.replace_all or false)
        if replace_err then
          return nil, string.format("edit %d: %s", i - 1, replace_err)
        end
        content = replaced
      end
      return content
    end)
    if not result then
      return { llm_output = err, is_error = true }
    end

    local n = #edits
    local s = n == 1 and "" or "s"
    return diff_result(result, string.format("applied %d edit%s to %s", n, s, shorten_path(result.path)))
  end,
})

maki.api.register_tool({
  name = "hashedit",
  kind = "edit",
  mutable_path = "path",
  permission_scope = "path",
  start_annotation = "edits",
  audiences = { "main", "general_sub", "interpreter" },
  description = HASHEDIT_DESCRIPTION,

  schema = {
    type = "object",
    properties = {
      path = {
        type = "string",
        description = "Absolute path to the file",
        required = true,
        alias = "file_path",
      },
      edits = {
        type = "array",
        description = "Hash-anchored edit operations applied from bottom to top",
        required = true,
        items = {
          type = "object",
          properties = {
            linenumber = {
              type = "string",
              description = 'Line to edit: "N" for a single line, or "N-M" to search an inclusive range (1-indexed); only the matched line is affected',
              required = true,
            },
            hash = {
              type = "string",
              description = "Short content hash of the line to edit, from read/grep/index output",
              required = true,
            },
            new_string = {
              type = "string",
              description = "Replacement text (multi-line ok). Omit or empty to delete.",
            },
            insert = {
              type = "boolean",
              description = "Insert new_string after the matched line instead of replacing it (default false)",
            },
          },
        },
      },
    },
  },

  header = edit_header,
  restore = edit_restore,

  handler = function(input, ctx)
    local edits = input.edits
    if not edits or #edits == 0 then
      return { llm_output = "provide at least one edit", is_error = true }
    end

    local result, err = apply_edit(input.path, ctx, function(content)
      return hashline.apply_edits(content, edits)
    end)
    if not result then
      return { llm_output = err, is_error = true }
    end

    local n = #edits
    local s = n == 1 and "" or "s"
    return diff_result(result, string.format("applied %d hash edit%s to %s", n, s, shorten_path(result.path)))
  end,
})
