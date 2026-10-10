-- Background work: two spawners and one reader.
--
--   background_run   detached OS process (setsid), output rings in the job store
--   background_task  detached subagent session, summary into the registry
--   background_output  reads either by pid, task id, or name
--
-- The spawners keep their own registries and lifecycles; the reader resolves a
-- handle against both so the model never has to remember which kind it spawned.
--
-- Lifetimes differ and the reader says so per response: processes are OS
-- children owned by the Rust job store (adopt() re-indexes them, so they
-- survive /reload and any loop respawn), while a task's run lives on this
-- plugin's thread and its id in this file's memory: a task dies when the
-- session ends or its loop respawns (model change, rewind, session load),
-- and its ids reset on /reload.

local NAME_PREFIX = "bg:"
local TAIL_LINES = 1024
local DEFAULT_QUERY_LINES = 50
local MAX_QUERY_LINES = TAIL_LINES
local LINE_MAX_BYTES = 400
local OUTPUT_MAX_BYTES = 6000
local NOTIFY_MAX_BYTES = 1200

local SUMMARY_MISSING_ERROR = "background task finished without providing a summary"
local NUDGE_SUMMARY =
  "You finished your work but did not provide a summary. Reply with a concise summary of what you did and found."

local opts = maki.api.register_options({
  max_concurrent = { default = 4, min = 1, desc = "Max concurrently running background subagents." },
  allow_model = {
    default = false,
    desc = "Expose a `model` input that overrides the subagent model. Only enable if you trust callers to pick an exact model themselves.",
  },
})

-- Jobs: NAME_PREFIX'd rows of the Rust job store, indexed three ways so the
-- reader can find a job by any handle. Survives /reload via adopt().
local by_name = {}
local by_pid = {}
local by_id = {}

-- Tasks: seq id -> { description, status = "working" | "done" | "error",
--                    result?, error?, parent_session? }
local tasks = {}
local next_id = 0

local function clip(s, max_bytes)
  if #s <= max_bytes then
    return s
  end
  -- A byte cut can split a multi-byte codepoint, and maki.session.notify
  -- raises on invalid UTF-8 instead of returning an error pair.
  local cut = max_bytes
  local b = s:byte(cut + 1)
  while cut > 0 and b and b >= 0x80 and b < 0xC0 do
    cut = cut - 1
    b = s:byte(cut + 1)
  end
  return s:sub(1, cut) .. "…"
end

local function notify_completion(session, body)
  local ok, _, err = pcall(maki.session.notify, body, { session = session, wake = true })
  if not ok then
    maki.log.warn(("background: notify raised: %s"):format(tostring(_)))
  elseif err then
    maki.log.warn(("background: notify failed: %s"):format(err))
  end
end

--------------------------------------------------------------------------------
-- Jobs (background_run)
--------------------------------------------------------------------------------

local function index_job(entry)
  by_name[NAME_PREFIX .. entry.name] = entry
  by_pid[entry.pid] = entry
  by_id[entry.id] = entry
end

local function exit_notify(entry, code)
  local body = ("[background_run] %s (pid %d) exited with code %s. Its output is still buffered: ask background_output with id=%d."):format(
    entry.name,
    entry.pid,
    tostring(code),
    entry.pid
  )
  notify_completion(entry.session, body)
end

local function on_exit(job_id, code)
  local entry = by_id[job_id]
  if entry then
    exit_notify(entry, code)
  end
end

-- Pick up jobs started before a /reload: their Lua callbacks were dropped,
-- their processes and output rings are still in the job store. Only running
-- jobs get on_exit re-attached: an exited job's notification already went out
-- or raced the reload, and attaching would fire the recorded exit a second
-- time. The output of either stays queryable.
local function adopt()
  for _, j in ipairs(maki.fn.joblist()) do
    local name = j.name
    if name and name:sub(1, #NAME_PREFIX) == NAME_PREFIX and not by_name[name] then
      index_job({
        id = j.id,
        pid = j.pid,
        name = name:sub(#NAME_PREFIX + 1),
        session = j.session,
        wake = true,
      })
      if j.status == "running" then
        local _, err = maki.fn.jobattach(j.id, { on_exit = on_exit })
        if err then
          maki.log.warn(("background_run %s: re-attach failed: %s"):format(name, err))
        end
      end
    end
  end
end
maki.defer_fn(adopt, 0)

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

-- Only advertise `model` when the plugin opts in: it costs tokens in every
-- background_task schema, and an off-by-default flag keeps the common path lean.
if opts.allow_model then
  task_schema.properties.model = {
    type = "string",
    description = 'Exact model spec, e.g. "ollama/glm-5.2". You tell maki the model; maki will not guess. Overrides model_tier.',
  }
end

local semaphore = maki.async.semaphore(opts.max_concurrent)

maki.api.register_tool({
  name = "background_run",
  kind = "execute",
  description = [[Launch a program detached from maki's process group (setsid) and return immediately with its OS pid.

- The process survives /reload; it is killed when this session ends or maki shuts down.
- stdout and stderr are buffered in maki (last 1024 lines each). Nothing lands in the transcript.
- When the pid exits, a notification arrives in this session automatically. Do not poll, sleep, or re-run the command to check on it.
- Read output any time with background_output, e.g. "the last 5 lines of pid <X>".]],
  audiences = { "main", "workflow" },
  schema = {
    type = "object",
    required = { "command" },
    additionalProperties = false,
    properties = {
      command = { type = "string", description = "Shell command line (runs through bash -c)." },
      name = {
        type = "string",
        description = "Short job handle (default: first word of the command). Starting a second job under a live name is refused, so a typo-proof name prevents double launches.",
      },
      cwd = { type = "string", description = "Working directory for the program (default: maki's cwd)." },
      wake = {
        type = "boolean",
        description = "Start an agent turn when the process exits (default true). False: report only at the session's next natural turn.",
      },
    },
  },
  header = function(input)
    return input.name or input.command
  end,
  handler = function(input)
    local command = input.command
    if type(command) ~= "string" or not command:match("%S") then
      return { llm_output = "error: command is required", is_error = true }
    end
    local label = (input.name or command:match("^%s*(%S+)") or "job"):gsub("%s+", "-")
    local sid = maki.session.current()

    local id, err = maki.fn.jobstart(command, {
      name = NAME_PREFIX .. label,
      cwd = input.cwd,
      scope = { session = sid },
      tail = TAIL_LINES,
      on_exit = on_exit,
    })
    if not id then
      return { llm_output = "error: " .. err, is_error = true }
    end

    local info, info_err = maki.fn.jobinfo(id)
    if not info then
      maki.fn.jobstop(id)
      return { llm_output = "error: job vanished at start: " .. tostring(info_err), is_error = true }
    end

    index_job({ id = id, pid = info.pid, name = label, session = sid, wake = input.wake ~= false })
    return {
      llm_output = ("Started %s: pid %d, job id %d. Output is buffered; ask background_output with id=%d. You will be notified when it exits."):format(
        label,
        info.pid,
        id,
        info.pid
      ),
    }
  end,
})

--------------------------------------------------------------------------------
-- Tasks (background_task)
--------------------------------------------------------------------------------

local function report_completion(id, entry)
  if not entry.parent_session then
    return
  end
  local body
  if entry.status == "done" then
    local truncated = clip(entry.result, NOTIFY_MAX_BYTES)
    local summary = (#truncated < #entry.result)
        and (truncated .. ("\n… [truncated, full result via background_output id=%s]"):format(id))
      or truncated
    body = ("[background_task %s] %s finished.\n\n%s"):format(id, entry.description, summary)
  else
    body = ("[background_task %s] %s failed: %s"):format(id, entry.description, entry.error)
  end
  notify_completion(entry.parent_session, body)
end

local function task_handler(input, ctx)
  local subagent_type = input.subagent_type or "research"
  if subagent_type ~= "research" and subagent_type ~= "general" then
    return { llm_output = "unknown subagent type: " .. subagent_type, is_error = true }
  end

  local audience = subagent_type == "research" and "research_sub" or "general_sub"
  local prompt_id = subagent_type == "research" and "research" or "general"

  local model, model_err = maki.agent.resolve_model(ctx, {
    tier = input.model_tier,
    spec = opts.allow_model and input.model or nil,
  })
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

  -- scope = "session" detaches the run from this call's cancel token, so
  -- the subagent outlives the turn; errors at session creation still answer
  -- to the caller synchronously, where the model can see them.
  local permit = semaphore:acquire()
  local sess, sess_err
  local ok, raised = pcall(function()
    sess, sess_err = maki.agent.session(ctx, {
      scope = "session",
      model_spec = model.spec,
      system = system,
      tools = tool_defs,
      audience = audience,
      name = input.description,
    })
  end)
  if not ok then
    permit:release()
    error(raised, 0)
  end
  if sess_err then
    permit:release()
    return { llm_output = sess_err, is_error = true }
  end

  next_id = next_id + 1
  local id = tostring(next_id)
  local entry = {
    description = input.description,
    status = "working",
    parent_session = maki.session.current(),
  }
  tasks[id] = entry

  -- scope = "session" on the runner drops the inherited cancel token and
  -- deadline_ms = false clears the cap: the tool call returned long ago, and
  -- work must not vanish with its turn. on_finish fires exactly once —
  -- completion, error, or abandonment — so no path can strand the entry.
  maki.async.run(function()
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
    return result.text
  end, {
    scope = "session",
    deadline_ms = false,
    on_finish = function(err, text)
      sess:close()
      permit:release()
      if err then
        entry.status = "error"
        entry.error = tostring(err)
        maki.log.warn(("background_task %s failed: %s"):format(id, entry.error))
      else
        entry.status = "done"
        entry.result = text
      end
      report_completion(id, entry)
    end,
  })

  return {
    llm_output = ("Started background task %s (%s). Continue with other work; a notification with the summary arrives here when it finishes. Read the full result with background_output id=%s if you need it."):format(
      id,
      input.description,
      id
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
2. Do not poll or wait for the result: you will be notified. A /reload cancels a running task — expect an "interrupted" wake instead of the summary, and ids reset.
3. Each invocation starts fresh - inline any needed context into the prompt.
4. Tell it to return concise summaries with file:line refs, not full file contents.
5. Read output any time with background_output, e.g. "task <id>" — ids reset on /reload.
6. It lives until the session ends or the agent loop respawns (model change, rewind, session load), unlike background_run jobs, which survive both.]],
  kind = "execute",
  audiences = { "main", "workflow" },
  schema = task_schema,
  handler = task_handler,
  header = function(input)
    return input.description
  end,
})

--------------------------------------------------------------------------------
-- The reader (background_output)
--------------------------------------------------------------------------------

-- Resolve one handle against both registries. A bare number is a pid first
-- (OS pids are large; task ids start at 1), then a task id; a word is a job
-- name first (uniqueness enforced live), then the newest task description
-- equal to it. The response header always names what matched.
local function resolve(handle)
  if not handle then
    return nil
  end
  local ref = tostring(handle)
  local num = tonumber(ref)
  if num then
    local pid = math.floor(num)
    if pid >= 0 and by_pid[pid] then
      return "job", by_pid[pid]
    end
    if tasks[ref] then
      return "task", tasks[ref], ref
    end
  end
  if by_name[NAME_PREFIX .. ref] then
    return "job", by_name[NAME_PREFIX .. ref]
  end
  local best_id, best_seq = nil, 0
  for id, entry in pairs(tasks) do
    if entry.description == ref and tonumber(id) > best_seq then
      best_id, best_seq = id, tonumber(id)
    end
  end
  if best_id then
    return "task", tasks[best_id], best_id
  end
  return nil
end

local function list_handles()
  local rows = {}
  for _, j in ipairs(maki.fn.joblist()) do
    local name = j.name
    if name and name:sub(1, #NAME_PREFIX) == NAME_PREFIX then
      local state = j.status == "running" and ("running, %ds"):format(j.elapsed_secs)
        or ("exited, code %s"):format(tostring(j.exit_code))
      rows[#rows + 1] = ("job %s pid=%d %s"):format(name:sub(#NAME_PREFIX + 1), j.pid, state)
    end
  end
  local ids = {}
  for id in pairs(tasks) do
    ids[#ids + 1] = id
  end
  table.sort(ids, function(a, b)
    return tonumber(a) < tonumber(b)
  end)
  for _, id in ipairs(ids) do
    local entry = tasks[id]
    local state = entry.status == "working" and "running"
      or (entry.status == "done" and "finished" or ("failed: %s"):format(entry.error))
    rows[#rows + 1] = ("task %s (%s) %s"):format(id, entry.description, state)
  end
  if #rows == 0 then
    return { llm_output = "No background jobs or tasks known to this session." }
  end
  return { llm_output = "Background handles:\n" .. table.concat(rows, "\n") }
end

local function read_job(entry, lines, stream)
  local info, err = maki.fn.jobinfo(entry.id)
  if not info then
    return { llm_output = "error: job is gone: " .. tostring(err), is_error = true }
  end

  local state = info.status == "running" and ("running, %ds"):format(info.elapsed_secs)
    or ("exited, code %s"):format(tostring(info.exit_code))
  local out_n = #(info.stdout_lines or {})
  local err_n = #(info.stderr_lines or {})
  local header = ("%s (job pid %d) %s | buffered: stdout=%d stderr=%d"):format(
    entry.name,
    entry.pid,
    state,
    out_n,
    err_n
  )
  if out_n == TAIL_LINES or err_n == TAIL_LINES then
    header = header .. " (ring wrapped, older lines evicted)"
  end

  local body = {}
  local blocks = {
    { want = "stdout", lines = info.stdout_lines or {}, mark = "| " },
    { want = "stderr", lines = info.stderr_lines or {}, mark = "! " },
  }
  for _, b in ipairs(blocks) do
    if not stream or stream == b.want then
      local n = #b.lines
      if n == 0 then
        body[#body + 1] = ("(%s: no output)"):format(b.want)
      else
        for i = math.max(1, n - lines + 1), n do
          body[#body + 1] = b.mark .. clip(b.lines[i], LINE_MAX_BYTES)
        end
      end
    end
  end
  return { header = header, body = body }
end

local function read_task(id, entry, lines)
  if entry.status == "working" then
    return {
      llm_output = ("Background task %s (%s) is still running. You will be notified when it finishes."):format(
        id,
        entry.description
      ),
    }
  end
  if entry.status == "error" then
    return {
      llm_output = ("Background task %s (%s) failed: %s"):format(id, entry.description, entry.error),
      is_error = true,
    }
  end
  local header = ("task %s (%s) finished"):format(id, entry.description)
  local all = {}
  for line in (entry.result .. "\n"):gmatch("([^\n]*)\n") do
    all[#all + 1] = line
  end
  local n = #all
  local body = {}
  if n > lines then
    body[#body + 1] = ("(%d earlier lines dropped; ask with a larger lines= for the whole result)"):format(n - lines)
  end
  for i = math.max(1, n - lines + 1), n do
    body[#body + 1] = all[i]
  end
  return { header = header, body = body, format = "markdown" }
end

maki.api.register_tool({
  name = "background_output",
  kind = "search",
  description = [[Read the buffered output of any background work: a detached process from background_run or a finished subagent from background_task.

- `id` is the pid or job name from background_run, or the task id from background_task. A bare number resolves as pid first, then task id; names resolve before task descriptions. With no `id`, lists every known job and task.
- `lines` is how many trailing lines to return (default 50, for a task's result text too). Only that slice enters the transcript: ask for the minimum that answers the question, 5-20 for a status check.
- `stream` (stdout/stderr) applies to jobs only; a task is one text result.
- Job buffers and names survive /reload; task ids and results do not. A task's transcript persists to /tasks only when it closes cleanly; one killed by /reload or a loop respawn leaves no trace.]],
  audiences = { "main", "workflow" },
  schema = {
    type = "object",
    additionalProperties = false,
    properties = {
      id = {
        type = "string",
        description = "Pid or job name (background_run), or task id / task description (background_task).",
      },
      lines = {
        type = "integer",
        description = ("Trailing lines to return (default %d, max %d)."):format(DEFAULT_QUERY_LINES, MAX_QUERY_LINES),
      },
      stream = {
        type = "string",
        enum = { "stdout", "stderr" },
        description = "Limit to one stream (jobs only; default: both).",
      },
    },
  },
  header = function(input)
    return input.id or "handles"
  end,
  handler = function(input)
    if not input.id or input.id == "" then
      return list_handles()
    end

    local kind, entry, task_id = resolve(input.id)
    if not kind then
      adopt()
      kind, entry, task_id = resolve(input.id)
    end
    if not kind then
      local listed = list_handles()
      return {
        llm_output = ("No background job or task matching %s. %s"):format(input.id, listed.llm_output),
        is_error = true,
      }
    end

    local lines = math.floor(tonumber(input.lines) or DEFAULT_QUERY_LINES)
    if lines < 1 then
      lines = 1
    end
    if lines > MAX_QUERY_LINES then
      lines = MAX_QUERY_LINES
    end

    local page
    if kind == "job" then
      page = read_job(entry, lines, input.stream)
    else
      page = read_task(task_id, entry, lines)
      if not page.header then
        return page
      end
    end

    -- Over budget: keep the newest lines, drop from the front. A single
    -- clipped line always fits, so `kept` is >= 1 whenever `body` is not empty.
    local body = page.body
    local total, kept = 0, 0
    for i = #body, 1, -1 do
      local next_total = total + #body[i] + 1
      if next_total > OUTPUT_MAX_BYTES then
        break
      end
      total = next_total
      kept = kept + 1
    end
    local first = math.max(1, #body - kept + 1)

    local out = { page.header }
    if first > 1 then
      out[#out + 1] = ("(%d older lines dropped to stay under %d bytes)"):format(first - 1, OUTPUT_MAX_BYTES)
    end
    for i = first, #body do
      out[#out + 1] = body[i]
    end
    return { llm_output = table.concat(out, "\n"), format = page.format }
  end,
})
