-- Background tasks: detached subagent sessions that outlive the turn that
-- spawned them. `maki.agent.session(ctx, { detached = true })` keeps the
-- cancel token independent of the turn's, so the run survives turn end; the
-- completion is reported back into the conversation with
-- `maki.session.notify`. Rust exposes the primitive, this plugin owns the
-- policy: concurrency cap, empty-summary nudges, and the result registry.

local SUMMARY_MISSING_ERROR = "background task finished without providing a summary"
local NUDGE_SUMMARY =
  "You finished your work but did not provide a summary. Reply with a concise summary of what you did and found."
local NOTIFY_MAX_BYTES = 1200

local opts = maki.api.register_options({
  max_concurrent = { default = 4, min = 1, desc = "Max concurrently running background subagents." },
})

local task_schema = {
  type = "object",
  required = { "description", "prompt" },
  additionalProperties = false,
  properties = {
    description = {
      type = "string",
      description = "Short (3-5 words) description of the task",
    },
    prompt = {
      type = "string",
      description = "Detailed task prompt for the agent",
    },
    subagent_type = {
      type = "string",
      description = 'Subagent type: "research" (read-only, default) or "general" (can modify files)',
    },
    model_tier = {
      type = "string",
      description = 'Model tier (optional, omit to use current model, capped at current tier):\n- "strong" (e.g. Opus): Deep reasoning, complex architecture, subtle bugs, most critical sections. ~5x cost of medium.\n- "medium" (e.g. Sonnet): Balanced. Refactors, features, multi-file changes.\n- "weak" (e.g. Haiku): Fast/cheap. Search, summarize, boilerplate, simple edits.',
    },
  },
}

local semaphore = maki.async.semaphore(opts.max_concurrent)

-- seq id -> { description, status = "working" | "done" | "error", task_id?,
--             result?, error?, parent_session? }
-- In-memory only: /reload starts a fresh registry, and transcripts of former
-- tasks stay available through /tasks.
local tasks = {}
local next_id = 0

local function report_completion(id, entry)
  local parent = entry.parent_session
  if not parent then
    return
  end
  local body
  if entry.status == "done" then
    local summary = (#entry.result > NOTIFY_MAX_BYTES)
        and (entry.result:sub(1, NOTIFY_MAX_BYTES) .. "\n… [truncated, full result via background_result]")
      or entry.result
    body = ("[background_task %s] %s finished.\n\n%s"):format(id, entry.description, summary)
  else
    body = ("[background_task %s] %s failed: %s"):format(id, entry.description, entry.error)
  end
  local _, err = maki.session.notify(body, { session = parent, wake = true })
  if err then
    maki.log.warn(("background_task %s: notify failed: %s"):format(id, err))
  end
end

local function handler(input, ctx)
  local subagent_type = input.subagent_type or "research"
  if subagent_type ~= "research" and subagent_type ~= "general" then
    return { llm_output = "unknown subagent type: " .. subagent_type, is_error = true }
  end

  local audience = subagent_type == "research" and "research_sub" or "general_sub"
  local prompt_id = subagent_type == "research" and "research" or "general"

  local model, model_err = maki.agent.resolve_model(ctx, { tier = input.model_tier })
  if model_err then
    return { llm_output = model_err, is_error = true }
  end
  local system, system_err = maki.agent.system_prompt(ctx, { prompt_id = prompt_id, instructions = true })
  if system_err then
    return { llm_output = system_err, is_error = true }
  end
  local tool_defs, tools_err = maki.agent.tools(ctx, { audience = audience, spec = model.spec })
  if tools_err then
    return { llm_output = tools_err, is_error = true }
  end

  next_id = next_id + 1
  local id = tostring(next_id)
  local parent_session = maki.session.current()
  tasks[id] = {
    description = input.description,
    status = "working",
    parent_session = parent_session,
  }

  maki.async.run(function()
    local permit = semaphore:acquire()
    local sess
    -- pcall so a raised error cannot leak the permit or the session.
    local ok, run_err = pcall(function()
      local sess_err
      sess, sess_err = maki.agent.session(ctx, {
        detached = true,
        model_spec = model.spec,
        system = system,
        tools = tool_defs,
        audience = audience,
        name = input.description,
      })
      if sess_err then
        error(sess_err, 0)
      end
      tasks[id].task_id = sess:id()

      local result, prompt_err = sess:prompt(input.prompt)
      if not prompt_err and result.text == "" then
        result, prompt_err = sess:prompt(NUDGE_SUMMARY)
      end
      if prompt_err then
        if result then
          error(("interrupted (%s). Partial output:\n%s"):format(prompt_err, result.text), 0)
        end
        error(prompt_err, 0)
      end
      if result.text == "" then
        error(SUMMARY_MISSING_ERROR, 0)
      end
      tasks[id].result = result.text
    end)

    if sess then
      sess:close()
    end
    permit:release()

    local entry = tasks[id]
    if ok then
      entry.status = "done"
    else
      entry.status = "error"
      entry.error = tostring(run_err)
      maki.log.warn(("background_task %s failed: %s"):format(id, entry.error))
    end
    report_completion(id, entry)
  end)

  return {
    llm_output = ("Started background task %s (%s). Continue with other work; a notification with the summary arrives here when it finishes. Read the full result with background_result if you need it."):format(
      id,
      input.description
    ),
  }
end

maki.api.register_tool({
  name = "background_task",
  description = [[Launch an autonomous subagent that runs in the background while the conversation continues.

Returns immediately with a task id; when the task finishes, a notification with its summary arrives in this conversation. The task also shows up in the /tasks list and can be inspected there.

Subagent types (set via `subagent_type`):
- `research` (default): Read-only tools. For codebase exploration or gathering context.
- `general`: Full tool access. For delegating implementation work.

Notes:
1. Use this for long-independent work the user shouldn't have to wait on. Prefer the synchronous `task` tool when you need the result to continue your current work.
2. Do not poll or wait for the result: you will be notified.
3. Each invocation starts fresh - inline any needed context into the prompt.
4. Tell it to return concise summaries with file:line refs, not full file contents.]],
  kind = "execute",
  audiences = { "main", "workflow" },
  schema = task_schema,
  handler = handler,
  header = function(input)
    return input.description
  end,
})

maki.api.register_tool({
  name = "background_result",
  description = [[Read the status or full result of a background task started with background_task.

- Pass the numeric `id` background_task returned.
- Returns "running" while the task is in flight, the full result when it finished, or the error when it failed.
- The task's live transcript is also visible in /tasks under its own chat entry.]],
  audiences = { "main", "workflow" },
  schema = {
    type = "object",
    required = { "id" },
    additionalProperties = false,
    properties = {
      id = { type = "string", description = "Task id returned by background_task" },
    },
  },
  handler = function(input)
    local entry = tasks[input.id]
    if not entry then
      return {
        llm_output = ("No background task with id %s in this run. Ids reset on /reload; older transcripts remain in /tasks."):format(
          input.id
        ),
        is_error = true,
      }
    end
    if entry.status == "working" then
      local hint = entry.task_id and (" (live transcript: /tasks entry " .. entry.task_id .. ")") or ""
      return { llm_output = ("Background task %s (%s) is still running%s. You will be notified when it finishes."):format(
        input.id,
        entry.description,
        hint
      ) }
    end
    if entry.status == "error" then
      return {
        llm_output = ("Background task %s (%s) failed: %s"):format(input.id, entry.description, entry.error),
        is_error = true,
      }
    end
    return { llm_output = entry.result, format = "markdown" }
  end,
  header = function(input)
    return "task " .. tostring(input.id)
  end,
})
