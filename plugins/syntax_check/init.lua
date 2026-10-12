-- syntax_check: layers the edit-family tool inputs and rejects a write whose
-- proposed content does not parse. Ships dark; turn it on with
-- `plugins.syntax_check = { enabled = true }`, which the config layer handles.
--
-- The plugin never edits a tool or wraps a write — it answers `nil, reason` at
-- the `tool.<name>.input` slot, which maki fires before permissions look at
-- the call, so a broken file is refused before it reaches disk and before the
-- user is asked to approve it. See maki.api.set_slot.

local Proposed = require("proposed")

-- The tools that compute content and write it. Layering one costs the
-- capability it declares (fs_write), so plugin.toml grants it.
local TOOLS = { "write", "edit", "multiedit", "edit_lines", "insert_lines" }

local function layer(prev, value, ctx)
  local reason = Proposed.reject(ctx.tool, value)
  if reason then
    return nil, reason
  end
  return prev(value, ctx)
end

for _, tool in ipairs(TOOLS) do
  maki.api.set_slot("tool." .. tool .. ".input", layer)
end
